-- Manage listings: pause / resume, delete with a guard, and up to 5 photos.

alter table public.items add column if not exists paused boolean not null default false;
alter table public.items add column if not exists images jsonb;   -- array of photo URLs, first = cover (also in image_url)

alter table public.items drop constraint if exists items_images_max5;
alter table public.items add constraint items_images_max5
  check (images is null or (jsonb_typeof(images) = 'array' and jsonb_array_length(images) <= 5));

-- Customers only see approved items that are not paused; the store sees its own, admins see all.
alter policy "public read items" on public.items using (
  (approval_status = 'approved' and not paused)
  or exists (select 1 from public.businesses b where b.id = items.business_id and b.owner_id = public.app_uid())
  or public.is_admin()
);

-- Don't let a store delete a listing that people are relying on:
-- an active auction with bids, or a rental with pending / accepted bookings from today on.
create or replace function public.items_delete_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.auction_listings a
             where a.item_id = OLD.id and a.status = 'active' and coalesce(a.bid_count,0) > 0) then
    raise exception 'item_in_use: auction has bids';
  end if;
  if exists (select 1 from public.rental_bookings b
             where b.item_id = OLD.id and b.status in ('pending','accepted') and b.requested_date >= current_date) then
    raise exception 'item_in_use: rental has upcoming bookings';
  end if;
  return OLD;
end; $$;
drop trigger if exists items_delete_guard on public.items;
create trigger items_delete_guard before delete on public.items for each row execute function public.items_delete_guard();
