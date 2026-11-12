-- A rider only sees (and can take) waiting jobs from stores on their own island
-- (all of Greater Malé is one area) or, while online, from stores within 20 km
-- that are in the SAME ATOLL. Before, the 20 km check alone let a Malé rider
-- see an island store whose saved GPS point was wrong (e.g. set from a phone
-- in Malé), so a Malé rider got a job picked up on AA. Maalhos.
-- Greater Malé (Malé, Hulhumalé, Villimalé) counts as Kaafu atoll ('K').
create or replace function public.island_atoll(p_island text)
returns text language sql immutable as $$
  select case
    when coalesce(p_island,'Malé') in ('Malé','Hulhumalé','Villimalé') then 'K'
    when position('. ' in p_island) > 0 then split_part(p_island, '. ', 1)
    else p_island end;
$$;

create or replace function public.rider_can_see_open_order(p_business_id text, p_is_rental boolean, p_ready boolean, p_needs_partner boolean)
returns boolean
language sql stable security definer set search_path = public as $$
  select (case when p_is_rental then coalesce(p_needs_partner,false) else coalesce(p_ready,false) end)
     and exists (
       select 1 from delivery_persons d, businesses b
        where d.user_id = public.app_uid() and b.id = p_business_id
          and (
            (coalesce(b.island,'Malé') in ('Malé','Hulhumalé','Villimalé') and coalesce(d.island,'Malé') in ('Malé','Hulhumalé','Villimalé'))
            or coalesce(b.island,'Malé') = coalesce(d.island,'Malé')
            or (public.island_atoll(b.island) = public.island_atoll(d.island)
                and d.online and d.lat is not null and d.lng is not null and b.lat is not null and b.lng is not null
                and d.location_updated_at > now() - interval '30 minutes'
                and 2 * 6371 * asin(sqrt(power(sin(radians(b.lat - d.lat)/2),2) + cos(radians(d.lat)) * cos(radians(b.lat)) * power(sin(radians(b.lng - d.lng)/2),2))) <= 20)
          )
     );
$$;

-- The same rule whenever a rider is put on an order (taking a job, accepting
-- an offer, a store offering it), whoever makes the change, so even a store
-- owner who is also a rider can't assign a job across atolls.
create or replace function public.rider_fits_business(p_rider_id text, p_business_id text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from delivery_persons d, businesses b
     where d.id = p_rider_id and b.id = p_business_id
       and (
         (coalesce(b.island,'Malé') in ('Malé','Hulhumalé','Villimalé') and coalesce(d.island,'Malé') in ('Malé','Hulhumalé','Villimalé'))
         or coalesce(b.island,'Malé') = coalesce(d.island,'Malé')
         or (public.island_atoll(b.island) = public.island_atoll(d.island)
             and d.online and d.lat is not null and d.lng is not null and b.lat is not null and b.lng is not null
             and d.location_updated_at > now() - interval '30 minutes'
             and 2 * 6371 * asin(sqrt(power(sin(radians(b.lat - d.lat)/2),2) + cos(radians(d.lat)) * cos(radians(b.lat)) * power(sin(radians(b.lng - d.lng)/2),2))) <= 20)
       ));
$$;

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
