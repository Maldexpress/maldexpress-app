-- 1) Item approval: every new item waits for a super admin before customers
--    see it. Existing items stay approved. Sellers can still edit any time;
--    an edit to a rejected item sends it back for review.
-- 2) Featured: sellers pay to feature an approved item (default MVR 50 for
--    3 days) by bank transfer to Maldexpress (or Swipe once Maldexpress's
--    own Swipe is set up). The super admin approves it, or features any item
--    directly. The number of featured spots is limited (platform_settings).

alter table public.items add column if not exists approval_status text not null default 'approved';
alter table public.items add column if not exists approval_note text;
alter table public.items add column if not exists submitted_at timestamptz;
alter table public.items add column if not exists featured_until timestamptz;
alter table public.items add column if not exists featured_source text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname='items_approval_status_check') then
    alter table public.items add constraint items_approval_status_check check (approval_status in ('pending','approved','rejected'));
  end if;
  if not exists (select 1 from pg_constraint where conname='items_featured_source_check') then
    alter table public.items add constraint items_featured_source_check check (featured_source is null or featured_source in ('paid','admin'));
  end if;
end $$;

-- Sellers can't approve or feature their own items: only the admin's RPCs
-- (and admins) change these columns.
create or replace function public.items_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() then return NEW; end if;
  if TG_OP = 'INSERT' then
    NEW.approval_status := 'pending'; NEW.approval_note := null; NEW.submitted_at := now();
    NEW.featured_until := null; NEW.featured_source := null;
  else
    NEW.approval_status := OLD.approval_status; NEW.approval_note := OLD.approval_note; NEW.submitted_at := OLD.submitted_at;
    NEW.featured_until := OLD.featured_until; NEW.featured_source := OLD.featured_source;
    if OLD.approval_status = 'rejected' and row(NEW.name, NEW.price, NEW.description, NEW.category, NEW.category_other_name, NEW.image_url, NEW.stock, NEW.listing_type)
         is distinct from row(OLD.name, OLD.price, OLD.description, OLD.category, OLD.category_other_name, OLD.image_url, OLD.stock, OLD.listing_type) then
      NEW.approval_status := 'pending'; NEW.approval_note := null; NEW.submitted_at := now();
    end if;
  end if;
  return NEW;
end; $$;
drop trigger if exists items_guard on public.items;
create trigger items_guard before insert or update on public.items for each row execute function public.items_guard();

-- Customers see approved items only; the store sees its own, admins see all.
alter policy "public read items" on public.items using (
  approval_status = 'approved'
  or exists (select 1 from public.businesses b where b.id = items.business_id and b.owner_id = public.app_uid())
  or public.is_admin()
);

-- Platform settings (one row): featured spots, price, days, and Maldexpress's
-- bank account shown to sellers paying Maldexpress (featured, Pro).
create table if not exists public.platform_settings (
  id int primary key default 1 check (id = 1),
  featured_slots int not null default 12 check (featured_slots between 1 and 200),
  featured_price numeric not null default 50 check (featured_price >= 0),
  featured_days int not null default 3 check (featured_days between 1 and 60),
  bank_account_name text,
  bank_account_number text,
  updated_at timestamptz default now()
);
insert into public.platform_settings (id) values (1) on conflict (id) do nothing;
alter table public.platform_settings enable row level security;
drop policy if exists "read platform settings" on public.platform_settings;
create policy "read platform settings" on public.platform_settings for select using (true);
drop policy if exists "admin update platform settings" on public.platform_settings;
create policy "admin update platform settings" on public.platform_settings for update using (public.is_admin()) with check (public.is_admin());
grant select, update on public.platform_settings to anon, authenticated;

-- Paid featured requests.
create table if not exists public.featured_requests (
  id text primary key,
  item_id text not null references public.items(id) on delete cascade,
  business_id text not null references public.businesses(id) on delete cascade,
  amount numeric not null,
  days int not null,
  payment_method text not null check (payment_method in ('bank_transfer','swipe')),
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  slip_url text,
  swipe_reference text,
  note text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by text,
  starts_at timestamptz,
  ends_at timestamptz
);
alter table public.featured_requests enable row level security;
grant select, insert, update on public.featured_requests to anon, authenticated;
drop policy if exists "owner insert featured request" on public.featured_requests;
create policy "owner insert featured request" on public.featured_requests for insert with check (
  exists (select 1 from public.businesses b where b.id = featured_requests.business_id and b.owner_id = public.app_uid())
  and exists (select 1 from public.items i where i.id = featured_requests.item_id and i.business_id = featured_requests.business_id)
);
drop policy if exists "owner or admin read featured requests" on public.featured_requests;
create policy "owner or admin read featured requests" on public.featured_requests for select using (
  public.is_admin() or exists (select 1 from public.businesses b where b.id = featured_requests.business_id and b.owner_id = public.app_uid())
);
drop policy if exists "admin update featured requests" on public.featured_requests;
create policy "admin update featured requests" on public.featured_requests for update using (public.is_admin()) with check (public.is_admin());
-- Price and days always come from the settings; a new request is always pending.
create or replace function public.featured_requests_fill() returns trigger
language plpgsql security definer set search_path = public as $$
declare s platform_settings;
begin
  select * into s from platform_settings where id = 1;
  NEW.amount := s.featured_price; NEW.days := s.featured_days; NEW.status := 'pending';
  NEW.resolved_at := null; NEW.resolved_by := null; NEW.starts_at := null; NEW.ends_at := null; NEW.created_at := now();
  if exists (select 1 from featured_requests r where r.item_id = NEW.item_id and r.status = 'pending') then
    raise exception 'featured_request_pending' using errcode = 'P0001';
  end if;
  return NEW;
end; $$;
drop trigger if exists featured_requests_fill on public.featured_requests;
create trigger featured_requests_fill before insert on public.featured_requests for each row execute function public.featured_requests_fill();

-- Admin actions.
create or replace function public.admin_approve_items(p_ids text[])
returns setof public.items language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin' using errcode = 'P0001'; end if;
  -- An auction's clock starts when it's approved, not while it waited.
  update auction_listings a set end_time = now() + (a.end_time - a.start_time), start_time = now()
   where a.item_id = any(p_ids) and a.status = 'active' and coalesce(a.bid_count,0) = 0
     and exists (select 1 from items i where i.id = a.item_id and i.approval_status <> 'approved');
  return query update items set approval_status = 'approved', approval_note = null where id = any(p_ids) returning *;
end; $$;
create or replace function public.admin_reject_items(p_ids text[], p_note text)
returns setof public.items language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin' using errcode = 'P0001'; end if;
  return query update items set approval_status = 'rejected', approval_note = nullif(trim(p_note),''), featured_until = null, featured_source = null
    where id = any(p_ids) returning *;
end; $$;
create or replace function public.featured_slots_used() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from items where featured_until > now() and approval_status = 'approved';
$$;
create or replace function public.admin_approve_featured_request(p_id text)
returns setof public.featured_requests language plpgsql security definer set search_path = public as $$
declare r featured_requests; it items; s platform_settings; v_start timestamptz; v_end timestamptz;
begin
  if not public.is_admin() then raise exception 'not_admin' using errcode = 'P0001'; end if;
  select * into r from featured_requests where id = p_id and status = 'pending' for update;
  if not found then return; end if;
  select * into it from items where id = r.item_id;
  if it.approval_status <> 'approved' then raise exception 'item_not_approved' using errcode = 'P0001'; end if;
  select * into s from platform_settings where id = 1;
  if coalesce(it.featured_until, now()) <= now() and featured_slots_used() >= s.featured_slots then
    raise exception 'featured_full' using errcode = 'P0001';
  end if;
  v_start := greatest(now(), coalesce(it.featured_until, now()));
  v_end := v_start + make_interval(days => r.days);
  update items set featured_until = v_end, featured_source = 'paid' where id = it.id;
  return query update featured_requests set status = 'approved', resolved_at = now(), resolved_by = public.app_uid(), starts_at = v_start, ends_at = v_end
    where id = p_id returning *;
end; $$;
create or replace function public.admin_reject_featured_request(p_id text, p_note text)
returns setof public.featured_requests language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin' using errcode = 'P0001'; end if;
  return query update featured_requests set status = 'rejected', note = nullif(trim(p_note),''), resolved_at = now(), resolved_by = public.app_uid()
    where id = p_id and status = 'pending' returning *;
end; $$;
-- Feature any approved item for p_days (0 = remove from featured).
create or replace function public.admin_feature_item(p_item_id text, p_days int)
returns setof public.items language plpgsql security definer set search_path = public as $$
declare it items; s platform_settings;
begin
  if not public.is_admin() then raise exception 'not_admin' using errcode = 'P0001'; end if;
  select * into it from items where id = p_item_id;
  if not found then return; end if;
  if coalesce(p_days,0) <= 0 then
    return query update items set featured_until = null, featured_source = null where id = p_item_id returning *;
    return;
  end if;
  if it.approval_status <> 'approved' then raise exception 'item_not_approved' using errcode = 'P0001'; end if;
  select * into s from platform_settings where id = 1;
  if coalesce(it.featured_until, now()) <= now() and featured_slots_used() >= s.featured_slots then
    raise exception 'featured_full' using errcode = 'P0001';
  end if;
  return query update items set featured_until = greatest(now(), coalesce(featured_until, now())) + make_interval(days => p_days),
                                featured_source = coalesce(featured_source, 'admin')
    where id = p_item_id returning *;
end; $$;
grant execute on function public.admin_approve_items(text[]), public.admin_reject_items(text[], text),
  public.featured_slots_used(), public.admin_approve_featured_request(text), public.admin_reject_featured_request(text, text),
  public.admin_feature_item(text, int) to anon, authenticated;
notify pgrst, 'reload schema';
