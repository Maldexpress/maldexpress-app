-- A rider only sees (and can take) jobs from stores on their OWN island.
-- Greater Malé (Malé, Hulhumalé, Villimalé) counts as one area. There is no
-- "nearby" exception any more: before, an online rider also got jobs from
-- stores within 20 km of the store's saved GPS point, so a Malé rider got a
-- job picked up on AA. Maalhos (the store's GPS point was saved in Malé).

create or replace function public.rider_fits_business(p_rider_id text, p_business_id text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from delivery_persons d, businesses b
     where d.id = p_rider_id and b.id = p_business_id
       and (
         (coalesce(b.island,'Malé') in ('Malé','Hulhumalé','Villimalé') and coalesce(d.island,'Malé') in ('Malé','Hulhumalé','Villimalé'))
         or coalesce(b.island,'Malé') = coalesce(d.island,'Malé')
       ));
$$;

create or replace function public.rider_can_see_open_order(p_business_id text, p_is_rental boolean, p_ready boolean, p_needs_partner boolean)
returns boolean
language sql stable security definer set search_path = public as $$
  select (case when p_is_rental then coalesce(p_needs_partner,false) else coalesce(p_ready,false) end)
     and exists (select 1 from delivery_persons d where d.user_id = public.app_uid()
                 and public.rider_fits_business(d.id, p_business_id));
$$;

-- The same rule whenever a rider is put on an order (taking a job, accepting
-- an offer, a store offering it), whoever makes the change, so even a store
-- owner who is also a rider can't assign a job from another island.
create or replace function public.orders_rider_island_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') = 'service_role' then return NEW; end if;
  if NEW.delivery_person_id is not null and NEW.delivery_person_id is distinct from OLD.delivery_person_id
     and not public.rider_fits_business(NEW.delivery_person_id, NEW.business_id) then
    raise exception 'rider_wrong_island' using errcode = 'P0001';
  end if;
  if NEW.pending_rider_id is not null and NEW.pending_rider_id is distinct from OLD.pending_rider_id
     and not public.rider_fits_business(NEW.pending_rider_id, NEW.business_id) then
    raise exception 'rider_wrong_island' using errcode = 'P0001';
  end if;
  return NEW;
end; $$;
drop trigger if exists orders_rider_island_guard on public.orders;
create trigger orders_rider_island_guard before update of delivery_person_id, pending_rider_id on public.orders
  for each row execute function public.orders_rider_island_guard();
