-- =========================================================================
-- ISLAND-WISE DELIVERY (2026-11-08)
-- Stores and delivery partners belong to an island (key like "Th. Vilufushi";
-- Greater Malé islands use plain names: Malé, Hulhumalé, Villimalé).
-- Orders record where they ship from and to, and how:
--   route 'male_zone'      Greater Malé -> Greater Malé (flat zone fee)
--         'boat_to_island' Greater Malé -> another island, by boat
--         'local'          on the store's own island
--         'boat_to_male'   another island -> Greater Malé, by boat
-- Island -> a different island isn't offered. For every route except
-- 'male_zone' the store sets the delivery charge when it approves.
-- Riders see jobs from their island, plus stores within 20 km while online
-- (lat/lng + location_updated_at, kept fresh by the app).
-- =========================================================================
alter table public.businesses add column if not exists island text;
alter table public.businesses add column if not exists lat double precision;
alter table public.businesses add column if not exists lng double precision;

alter table public.delivery_persons add column if not exists island text;
alter table public.delivery_persons add column if not exists online boolean not null default false;
alter table public.delivery_persons add column if not exists lat double precision;
alter table public.delivery_persons add column if not exists lng double precision;
alter table public.delivery_persons add column if not exists location_updated_at timestamptz;

alter table public.orders add column if not exists origin_island text;
alter table public.orders add column if not exists dest_island text;
alter table public.orders add column if not exists route text;
alter table public.orders drop constraint if exists orders_route_check;
alter table public.orders add constraint orders_route_check
  check (route is null or route in ('male_zone','boat_to_island','local','boat_to_male'));

-- Approve now takes the store's delivery charge for non-zone routes.
drop function if exists public.approve_swipe_order(text);
create or replace function public.approve_swipe_order(p_order_id text, p_delivery_charge numeric default null)
returns setof orders
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_delivery_charge is not null and (p_delivery_charge < 0 or p_delivery_charge > 10000) then
    raise exception 'invalid_delivery_charge' using errcode = 'P0001';
  end if;
  return query
    update orders o set
      payment_status = 'awaiting_swipe',
      delivery_fee = case when o.route in ('boat_to_island','local','boat_to_male') then p_delivery_charge else o.delivery_fee end,
      delivery_partner_payout = case when o.route in ('boat_to_island','local','boat_to_male') then p_delivery_charge else o.delivery_partner_payout end,
      total = case when o.route in ('boat_to_island','local','boat_to_male')
                   then greatest(0, coalesce(o.items_total,0) - coalesce(o.discount_amount,0)) + p_delivery_charge + coalesce(o.extra_delivery_fee,0)
                   else o.total end
    where o.id = p_order_id
      and o.payment_method = 'swipe' and o.payment_status = 'awaiting_approval'
      and o.status is distinct from 'declined'
      and (o.route is null or o.route = 'male_zone' or p_delivery_charge is not null)
      and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
      and exists (select 1 from business_swipe_accounts s where s.business_id = o.business_id)
    returning o.*;
end;
$$;
grant execute on function public.approve_swipe_order(text, numeric) to anon, authenticated;
