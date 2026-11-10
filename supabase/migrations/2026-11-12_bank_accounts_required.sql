-- Stores and riders must have a bank account before they can work on the app,
-- so stores can pay riders (and Maldexpress) straight to an account.
--
-- * Riders' accounts live in their own table, NOT on delivery_persons (which
--   other users can read). A rider reads/writes their own; a store can read the
--   account of a rider who has delivered (or is delivering) one of its orders;
--   admins read all.
-- * A rider can't take a job (orders.delivery_person_id set) without one.
-- * A store can't add items without its account name + number (stores already
--   give them at sign-up; this stops a store that cleared them).
-- Riders no longer collect cash, so they never owe a store anything.

create table if not exists public.rider_bank_accounts (
  rider_id text primary key references public.delivery_persons(id) on delete cascade,
  user_id text not null default public.app_uid(),
  account_name text not null check (length(trim(account_name)) between 2 and 80),
  account_number text not null check (account_number ~ '^[0-9 -]{6,30}$'),
  bank_name text,
  updated_at timestamptz not null default now()
);
alter table public.rider_bank_accounts enable row level security;

create or replace function public.rider_bank_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    NEW.user_id := public.app_uid();
    if not exists (select 1 from delivery_persons d where d.id = NEW.rider_id and d.user_id = NEW.user_id) then
      raise exception 'not_your_rider_profile';
    end if;
  end if;
  NEW.updated_at := now();
  return NEW;
end; $$;
drop trigger if exists rider_bank_guard on public.rider_bank_accounts;
create trigger rider_bank_guard before insert or update on public.rider_bank_accounts
  for each row execute function public.rider_bank_guard();

drop policy if exists "rider bank read"   on public.rider_bank_accounts;
drop policy if exists "rider bank insert" on public.rider_bank_accounts;
drop policy if exists "rider bank update" on public.rider_bank_accounts;
create policy "rider bank read" on public.rider_bank_accounts for select to anon, authenticated using (
  user_id = public.app_uid()
  or public.is_admin()
  or exists (select 1 from public.orders o join public.businesses b on b.id = o.business_id
             where o.delivery_person_id = rider_bank_accounts.rider_id and b.owner_id = public.app_uid())
);
create policy "rider bank insert" on public.rider_bank_accounts for insert to anon, authenticated
  with check (user_id = public.app_uid());
create policy "rider bank update" on public.rider_bank_accounts for update to anon, authenticated
  using (user_id = public.app_uid()) with check (user_id = public.app_uid());
grant select, insert, update on public.rider_bank_accounts to anon, authenticated;

-- No job without a bank account.
create or replace function public.orders_rider_bank_required() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if NEW.delivery_person_id is not null
     and NEW.delivery_person_id is distinct from OLD.delivery_person_id
     and not exists (select 1 from rider_bank_accounts a where a.rider_id = NEW.delivery_person_id) then
    raise exception 'rider_bank_required';
  end if;
  return NEW;
end; $$;
drop trigger if exists orders_rider_bank_required on public.orders;
create trigger orders_rider_bank_required before update on public.orders
  for each row execute function public.orders_rider_bank_required();

-- No new items without the store's account.
create or replace function public.items_store_bank_required() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from businesses b where b.id = NEW.business_id
                 and coalesce(trim(b.account_number), '') <> '' and coalesce(trim(b.account_name), '') <> '') then
    raise exception 'store_bank_required';
  end if;
  return NEW;
end; $$;
drop trigger if exists items_store_bank_required on public.items;
create trigger items_store_bank_required before insert on public.items
  for each row execute function public.items_store_bank_required();
