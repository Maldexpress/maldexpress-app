-- Per-store item limit. Every store still gets 250 items unless the Super
-- Admin gives it a different limit (Admin → Stores → a store → Item limit).
-- Store owners can't change their own limit: the guard below keeps the old
-- value on any change that doesn't come from an admin.

alter table public.businesses
  add column if not exists item_limit integer
  check (item_limit is null or (item_limit between 1 and 10000));

comment on column public.businesses.item_limit is
  'Most items this store may list. NULL = the default 250. Only admins can change it.';

-- Security invoker on purpose: current_user is then the app's role (anon /
-- authenticated) for requests from the app, and an owner role for SQL run
-- directly on the database (migrations, the dashboard), which is let through.
create or replace function public.businesses_limit_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user not in ('anon', 'authenticated') or public.is_admin() then return NEW; end if;
  if TG_OP = 'INSERT' then
    NEW.item_limit := null;
  elsif NEW.item_limit is distinct from OLD.item_limit then
    NEW.item_limit := OLD.item_limit;
  end if;
  return NEW;
end; $$;

drop trigger if exists businesses_limit_guard on public.businesses;
create trigger businesses_limit_guard before insert or update on public.businesses
  for each row execute function public.businesses_limit_guard();

-- Same trigger as before, now reading the store's own limit.
create or replace function public.items_store_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare lim integer;
begin
  select coalesce(item_limit, 250) into lim from businesses where id = NEW.business_id;
  if (select count(*) from items where business_id = NEW.business_id) >= coalesce(lim, 250) then
    raise exception 'item_limit_reached';
  end if;
  return NEW;
end; $$;

-- Admin sets a store's limit. NULL (or 250) puts it back on the default.
create or replace function public.admin_set_item_limit(p_business_id text, p_limit integer)
returns public.businesses
language plpgsql security definer set search_path = public as $$
declare b public.businesses;
begin
  if not public.is_admin() then raise exception 'not_admin' using errcode = 'P0001'; end if;
  if p_limit is not null and (p_limit < 1 or p_limit > 10000) then
    raise exception 'bad_limit' using errcode = 'P0001';
  end if;
  update businesses set item_limit = nullif(p_limit, 250) where id = p_business_id returning * into b;
  if b.id is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  return b;
end; $$;

revoke all on function public.admin_set_item_limit(text, integer) from public;
grant execute on function public.admin_set_item_limit(text, integer) to anon, authenticated;

-- GREENLINK (AA. Maalhos) may list up to 2000 items.
update public.businesses set item_limit = 2000 where id = 'biz_j8xmi68';
