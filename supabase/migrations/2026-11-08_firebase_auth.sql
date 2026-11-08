begin;
-- =========================================================================
-- FIREBASE SIGN-IN (2026-11-08). Accounts now live in Firebase Auth
-- (project "maldexpress"); Supabase only stores data. Supabase verifies the
-- Firebase ID token (third-party auth, issuer below). Firebase tokens carry
-- no Supabase "role" claim, so requests run as the anon role: every rule
-- therefore identifies the user with public.app_uid(), which returns the
-- Firebase uid only for a token from this Firebase project with a verified
-- email, and null otherwise (including for signed-out visitors).
-- User id columns change from uuid (references auth.users) to text.
-- The delivery-pool private key is set separately and never committed.
-- =========================================================================
create or replace function public.app_uid()
returns text
language sql
stable
set search_path = public
as $$
  select case
    when auth.jwt()->>'iss' = 'https://securetoken.google.com/maldexpress'
     and auth.jwt()->>'aud' = 'maldexpress'
     and coalesce((auth.jwt()->>'email_verified')::boolean, false)
    then nullif(auth.jwt()->>'sub', '')
  end;
$$;
grant execute on function public.app_uid() to anon, authenticated;

alter table public.admins drop constraint if exists admins_user_id_fkey;
alter table public.auction_bids drop constraint if exists auction_bids_bidder_id_fkey;
alter table public.auction_listings drop constraint if exists auction_listings_current_highest_bidder_fkey;
alter table public.businesses drop constraint if exists businesses_owner_id_fkey;
alter table public.category_requests drop constraint if exists category_requests_resolved_by_fkey;
alter table public.customer_addresses drop constraint if exists customer_addresses_customer_id_fkey;
alter table public.delivery_persons drop constraint if exists delivery_persons_user_id_fkey;
alter table public.orders drop constraint if exists orders_customer_id_fkey;
alter table public.pro_upgrade_requests drop constraint if exists pro_upgrade_requests_resolved_by_fkey;
alter table public.rental_bookings drop constraint if exists rental_bookings_customer_id_fkey;
alter table public.user_profiles drop constraint if exists user_profiles_user_id_fkey;
drop policy if exists "admin read own admin row" on public.admins;
drop policy if exists "customer valid bid" on public.auction_bids;
drop policy if exists "public read bids" on public.auction_bids;
drop policy if exists "owner insert own auction" on public.auction_listings;
drop policy if exists "public read auctions" on public.auction_listings;
drop policy if exists "signed-in update auction" on public.auction_listings;
drop policy if exists "admin update any business" on public.businesses;
drop policy if exists "owner delete business" on public.businesses;
drop policy if exists "owner insert business" on public.businesses;
drop policy if exists "owner update business" on public.businesses;
drop policy if exists "public read businesses" on public.businesses;
drop policy if exists "admin read all category requests" on public.category_requests;
drop policy if exists "admin update category requests" on public.category_requests;
drop policy if exists "owner insert own category request" on public.category_requests;
drop policy if exists "owner read own category requests" on public.category_requests;
drop policy if exists "admin manage custom categories" on public.custom_categories;
drop policy if exists "public read custom categories" on public.custom_categories;
drop policy if exists "customer manage own addresses" on public.customer_addresses;
drop policy if exists "public read delivery" on public.delivery_persons;
drop policy if exists "self insert delivery" on public.delivery_persons;
drop policy if exists "self update delivery" on public.delivery_persons;
drop policy if exists "owner manage items" on public.items;
drop policy if exists "public read items" on public.items;
drop policy if exists "customer insert own order" on public.orders;
drop policy if exists "read own or relevant orders" on public.orders;
drop policy if exists "update own or relevant orders" on public.orders;
drop policy if exists "admin read all upgrade requests" on public.pro_upgrade_requests;
drop policy if exists "admin update upgrade requests" on public.pro_upgrade_requests;
drop policy if exists "owner delete own upgrade request" on public.pro_upgrade_requests;
drop policy if exists "owner insert own upgrade request" on public.pro_upgrade_requests;
drop policy if exists "owner read own upgrade requests" on public.pro_upgrade_requests;
drop policy if exists "business read own bookings" on public.rental_bookings;
drop policy if exists "business update own bookings" on public.rental_bookings;
drop policy if exists "customer insert own booking" on public.rental_bookings;
drop policy if exists "customer read own bookings" on public.rental_bookings;
drop policy if exists "admin read all profiles" on public.user_profiles;
drop policy if exists "self insert own profile" on public.user_profiles;
drop policy if exists "self read own profile" on public.user_profiles;
drop policy if exists "self update own profile" on public.user_profiles;
alter table public.admins alter column user_id type text using user_id::text;
alter table public.auction_bids alter column bidder_id type text using bidder_id::text;
alter table public.auction_listings alter column current_highest_bidder type text using current_highest_bidder::text;
alter table public.businesses alter column owner_id type text using owner_id::text;
alter table public.category_requests alter column resolved_by type text using resolved_by::text;
alter table public.customer_addresses alter column customer_id type text using customer_id::text;
alter table public.delivery_persons alter column user_id type text using user_id::text;
alter table public.orders alter column customer_id type text using customer_id::text;
alter table public.pro_upgrade_requests alter column resolved_by type text using resolved_by::text;
alter table public.rental_bookings alter column customer_id type text using customer_id::text;
alter table public.user_profiles alter column user_id type text using user_id::text;
create policy "admin read own admin row" on public.admins as permissive for select to public using ((( SELECT public.app_uid() AS uid) = user_id));
create policy "customer valid bid" on public.auction_bids as permissive for insert to public with check (((bidder_id = ( SELECT public.app_uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM auction_listings al
  WHERE ((al.id = auction_bids.auction_id) AND (al.status = 'active'::text) AND (al.end_time > now()) AND (auction_bids.bid_amount >= COALESCE((al.current_highest_bid + al.bid_increment), al.starting_price)) AND (NOT (EXISTS ( SELECT 1
           FROM businesses b
          WHERE ((b.id = al.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid)))))))))));
create policy "public read bids" on public.auction_bids as permissive for select to public using (true);
create policy "owner insert own auction" on public.auction_listings as permissive for insert to public with check ((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = auction_listings.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid))))));
create policy "public read auctions" on public.auction_listings as permissive for select to public using (true);
create policy "signed-in update auction" on public.auction_listings as permissive for update to authenticated using ((status = ANY (ARRAY['active'::text, 'ended'::text]))) with check (true);
create policy "admin update any business" on public.businesses as permissive for update to public using (is_admin());
create policy "owner delete business" on public.businesses as permissive for delete to public using ((( SELECT public.app_uid() AS uid) = owner_id));
create policy "owner insert business" on public.businesses as permissive for insert to public with check ((( SELECT public.app_uid() AS uid) = owner_id));
create policy "owner update business" on public.businesses as permissive for update to public using ((( SELECT public.app_uid() AS uid) = owner_id));
create policy "public read businesses" on public.businesses as permissive for select to public using (true);
create policy "admin read all category requests" on public.category_requests as permissive for select to public using (is_admin());
create policy "admin update category requests" on public.category_requests as permissive for update to public using (is_admin());
create policy "owner insert own category request" on public.category_requests as permissive for insert to public with check ((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = category_requests.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid))))));
create policy "owner read own category requests" on public.category_requests as permissive for select to public using ((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = category_requests.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid))))));
create policy "admin manage custom categories" on public.custom_categories as permissive for all to public using (is_admin());
create policy "public read custom categories" on public.custom_categories as permissive for select to public using (true);
create policy "customer manage own addresses" on public.customer_addresses as permissive for all to public using ((( SELECT public.app_uid() AS uid) = customer_id)) with check ((( SELECT public.app_uid() AS uid) = customer_id));
create policy "public read delivery" on public.delivery_persons as permissive for select to public using (true);
create policy "self insert delivery" on public.delivery_persons as permissive for insert to public with check ((( SELECT public.app_uid() AS uid) = user_id));
create policy "self update delivery" on public.delivery_persons as permissive for update to public using ((( SELECT public.app_uid() AS uid) = user_id));
create policy "owner manage items" on public.items as permissive for all to public using ((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = items.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid)))))) with check ((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = items.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid))))));
create policy "public read items" on public.items as permissive for select to public using (true);
create policy "customer insert own order" on public.orders as permissive for insert to public with check (((public.app_uid() = customer_id) AND (swipe_reference IS NULL) AND (swipe_payment_link IS NULL) AND (paid_at IS NULL) AND (swipe_fee IS NULL) AND (platform_fee IS NULL) AND (platform_fee_due IS NULL) AND (fee_settled_at IS NULL) AND (((rental_item_id IS NOT NULL) AND (((payment_method = 'transfer'::text) AND (payment_status = 'pending_transfer'::text)) OR ((payment_method = 'cash_on_pickup'::text) AND (payment_status = 'pending_cash'::text)) OR ((payment_method = 'swipe'::text) AND (payment_status = 'awaiting_swipe'::text) AND (EXISTS ( SELECT 1
   FROM business_swipe_accounts s
  WHERE (s.business_id = orders.business_id)))))) OR ((rental_item_id IS NULL) AND (payment_status = 'awaiting_completion'::text)) OR ((rental_item_id IS NULL) AND (payment_method = 'swipe'::text) AND (payment_status = 'awaiting_approval'::text)))));
create policy "read own or relevant orders" on public.orders as permissive for select to public using (((( SELECT public.app_uid() AS uid) = customer_id) OR (EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = orders.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid))))) OR (EXISTS ( SELECT 1
   FROM delivery_persons d
  WHERE ((d.id = orders.delivery_person_id) AND (d.user_id = ( SELECT public.app_uid() AS uid))))) OR (EXISTS ( SELECT 1
   FROM delivery_persons d
  WHERE ((d.id = orders.pending_rider_id) AND (d.user_id = ( SELECT public.app_uid() AS uid))))) OR ((delivery_person_id IS NULL) AND (EXISTS ( SELECT 1
   FROM delivery_persons d
  WHERE (d.user_id = ( SELECT public.app_uid() AS uid)))))));
create policy "update own or relevant orders" on public.orders as permissive for update to public using (((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = orders.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid))))) OR (( SELECT public.app_uid() AS uid) = customer_id) OR (((delivery_person_id IS NULL) AND (ready_for_pickup = true)) OR (EXISTS ( SELECT 1
   FROM delivery_persons d
  WHERE ((d.id = orders.delivery_person_id) AND (d.user_id = ( SELECT public.app_uid() AS uid)))))))) with check (((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = orders.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid))))) OR (( SELECT public.app_uid() AS uid) = customer_id) OR (EXISTS ( SELECT 1
   FROM delivery_persons d
  WHERE ((d.id = orders.delivery_person_id) AND (d.user_id = ( SELECT public.app_uid() AS uid)))))));
create policy "admin read all upgrade requests" on public.pro_upgrade_requests as permissive for select to public using (is_admin());
create policy "admin update upgrade requests" on public.pro_upgrade_requests as permissive for update to public using (is_admin());
create policy "owner delete own upgrade request" on public.pro_upgrade_requests as permissive for delete to public using ((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = pro_upgrade_requests.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid))))));
create policy "owner insert own upgrade request" on public.pro_upgrade_requests as permissive for insert to public with check ((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = pro_upgrade_requests.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid))))));
create policy "owner read own upgrade requests" on public.pro_upgrade_requests as permissive for select to public using ((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = pro_upgrade_requests.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid))))));
create policy "business read own bookings" on public.rental_bookings as permissive for select to public using ((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = rental_bookings.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid))))));
create policy "business update own bookings" on public.rental_bookings as permissive for update to public using ((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.id = rental_bookings.business_id) AND (b.owner_id = ( SELECT public.app_uid() AS uid))))));
create policy "customer insert own booking" on public.rental_bookings as permissive for insert to public with check ((( SELECT public.app_uid() AS uid) = customer_id));
create policy "customer read own bookings" on public.rental_bookings as permissive for select to public using ((public.app_uid() = customer_id));
create policy "admin read all profiles" on public.user_profiles as permissive for select to public using (is_admin());
create policy "self insert own profile" on public.user_profiles as permissive for insert to public with check ((( SELECT public.app_uid() AS uid) = user_id));
create policy "self read own profile" on public.user_profiles as permissive for select to public using ((( SELECT public.app_uid() AS uid) = user_id));
create policy "self update own profile" on public.user_profiles as permissive for update to public using ((public.app_uid() = user_id)) with check ((public.app_uid() = user_id));
alter policy "owner delete product images" on storage.objects using (((bucket_id = 'product-images'::text) AND ((storage.foldername(name))[1] = (public.app_uid())::text)));
alter policy "owner update product images" on storage.objects using (((bucket_id = 'product-images'::text) AND ((storage.foldername(name))[1] = (public.app_uid())::text)));
alter policy "owner upload product images" on storage.objects with check (((bucket_id = 'product-images'::text) AND ((storage.foldername(name))[1] = (public.app_uid())::text)));
drop function if exists customer_checkout_blocked(uuid) cascade;
CREATE OR REPLACE FUNCTION public.customer_checkout_blocked(p_uid text DEFAULT public.app_uid())
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select o.id
  from orders o
  where o.customer_id = p_uid
    and o.status = 'delivered'
    and (
      o.payment_review in ('problem','resubmitted')
      or (o.payment_review is distinct from 'approved'
          and o.payment_status in ('pending_transfer','pending_cash'))
    )
  order by o.created_at
  limit 1;
$function$;
CREATE OR REPLACE FUNCTION public.place_bid(p_auction_id text, p_bid_amount numeric)
 RETURNS SETOF auction_listings
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with updated as (
    update auction_listings
    set current_highest_bid = p_bid_amount, current_highest_bidder = public.app_uid(), bid_count = coalesce(bid_count,0) + 1
    where id = p_auction_id
      and status = 'active'
      and end_time > now()
      and public.app_uid() is not null
      and not exists (select 1 from businesses b where b.id = auction_listings.business_id and b.owner_id = public.app_uid())
      and (
        (current_highest_bid is null and p_bid_amount >= starting_price)
        or (current_highest_bid is not null and p_bid_amount >= current_highest_bid + bid_increment)
      )
    returning *
  ),
  ins as (
    insert into auction_bids (id, auction_id, bidder_id, bid_amount)
    select 'bid_' || replace(gen_random_uuid()::text, '-', ''), p_auction_id, public.app_uid(), p_bid_amount
    from updated
    returning 1
  )
  select * from updated;
$function$;
CREATE OR REPLACE FUNCTION public.cancel_booking_request(p_booking_id text)
 RETURNS SETOF rental_bookings
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update rental_bookings
  set status = 'cancelled'
  where id = p_booking_id and customer_id = public.app_uid() and status = 'pending'
  returning *;
$function$;
CREATE OR REPLACE FUNCTION public.set_default_address(p_address_id text, p_category text)
 RETURNS SETOF customer_addresses
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with unset as (
    update customer_addresses set is_default = false
    where customer_id = public.app_uid() and category = p_category and is_default = true
  )
  update customer_addresses set is_default = true
  where id = p_address_id and customer_id = public.app_uid() and category = p_category
  returning *;
$function$;
CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select exists(select 1 from admins where user_id = public.app_uid()); $function$;
CREATE OR REPLACE FUNCTION public.submit_transfer_slip(p_order_id text, p_slip_url text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders
  set payment_status = 'slip_uploaded', slip_url = p_slip_url, payment_method = 'transfer'
  where id = p_order_id and customer_id = public.app_uid()
  returning *;
$function$;
CREATE OR REPLACE FUNCTION public.settle_payout(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders
  set payment_status = 'settled'
  where id = p_order_id
    and exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = public.app_uid())
  returning *;
$function$;
CREATE OR REPLACE FUNCTION public.mark_payout_paid(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders
  set payout_status = 'settled'
  where id = p_order_id
    and exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = public.app_uid())
  returning *;
$function$;
CREATE OR REPLACE FUNCTION public.confirm_cash_received(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set payment_status = 'cash_collected'
  where o.id = p_order_id
    and o.status = 'out_for_delivery'
    and (
      exists (select 1 from delivery_persons d where d.id = o.delivery_person_id and d.user_id = public.app_uid())
      or (o.self_delivery = true and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid()))
    )
  returning o.*;
$function$;
CREATE OR REPLACE FUNCTION public.mark_delivered(p_order_id text, p_boat_photo_url text DEFAULT NULL::text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders
  set
    status = 'delivered',
    payout_status = case when delivery_type = 'free' then 'pending' else payout_status end,
    handoff_photo_url = case when delivery_target_type = 'boat' and rental_item_id is null then p_boat_photo_url else handoff_photo_url end
  where id = p_order_id
    and status is distinct from 'delivered'
    and (rental_item_id is not null or status = 'out_for_delivery')
    and (rental_item_id is null or payment_status = 'paid')
    and (delivery_target_type is distinct from 'boat' or rental_item_id is not null or p_boat_photo_url is not null)
    and exists (select 1 from delivery_persons d where d.id = orders.delivery_person_id and d.user_id = public.app_uid())
  returning *;
$function$;
CREATE OR REPLACE FUNCTION public.mark_rental_fulfilled(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders
  set status = 'delivered'
  where id = p_order_id
    and rental_item_id is not null
    and status is distinct from 'delivered'
    and delivery_person_id is null
    and payment_status = 'paid'
    and exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = public.app_uid())
  returning *;
$function$;
CREATE OR REPLACE FUNCTION public.offer_rental_delivery(p_order_id text, p_fee numeric, p_timing text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders
  set
    needs_delivery_partner = true,
    delivery_partner_payout = p_fee,
    rental_payout_timing = case when p_timing = 'upfront' then 'upfront' else 'after' end
  where id = p_order_id
    and rental_item_id is not null
    and rental_fulfillment = 'deliver'
    and delivery_person_id is null
    and status is distinct from 'delivered'
    and p_fee > 0
    and exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = public.app_uid())
  returning *;
$function$;
CREATE OR REPLACE FUNCTION public.claim_rental_job(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rider_id text; v_rider_name text;
begin
  select id, name into v_rider_id, v_rider_name from delivery_persons where user_id = public.app_uid();
  if v_rider_id is null then return; end if;
  return query
  update orders o set
    delivery_person_id = v_rider_id,
    delivery_person_name = v_rider_name,
    payout_status = case when o.rental_payout_timing = 'upfront' then 'pending' else o.payout_status end
  where o.id = p_order_id
    and o.rental_item_id is not null
    and o.needs_delivery_partner = true
    and o.delivery_person_id is null
    and o.status is distinct from 'delivered'
  returning o.*;
end;
$function$;
CREATE OR REPLACE FUNCTION public.decrement_rental_stock(p_item_id text)
 RETURNS SETOF items
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update items
  set stock = stock - 1
  where id = p_item_id
    and stock > 0
    and public.app_uid() is not null
  returning *;
$function$;
CREATE OR REPLACE FUNCTION public.approve_order_payment(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders
  set payment_status = 'paid', payment_review = 'approved', payment_problem_reason = null
  where id = p_order_id
    and exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = public.app_uid())
  returning *;
$function$;
CREATE OR REPLACE FUNCTION public.mark_rental_returned(p_order_id text, p_fee_collected numeric DEFAULT NULL::numeric)
 RETURNS SETOF orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_result orders;
begin
  update orders o set
    rental_returned_at = now(),
    rental_return_fee_status = case when o.rental_fee_timing = 'on_return' then 'collected' else o.rental_return_fee_status end
  where o.id = p_order_id
    and o.rental_item_id is not null
    and o.status = 'delivered'
    and o.rental_returned_at is null
    and (o.rental_fee_timing is distinct from 'on_return' or p_fee_collected is not null)
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
  returning o.* into v_result;

  if v_result.id is null then
    return;
  end if;

  update items set stock = stock + 1 where id = v_result.rental_item_id;

  return query select v_result.*;
end;
$function$;
CREATE OR REPLACE FUNCTION public.mark_order_delivered_by_business(p_order_id text, p_boat_photo_url text DEFAULT NULL::text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set
    status = 'delivered',
    handoff_photo_url = case when o.delivery_target_type = 'boat' then p_boat_photo_url else o.handoff_photo_url end
  where o.id = p_order_id
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
    and o.self_delivery = true
    and o.status = 'out_for_delivery'
    and (o.delivery_target_type is distinct from 'boat' or p_boat_photo_url is not null)
  returning o.*;
$function$;
CREATE OR REPLACE FUNCTION public.mark_order_out_for_delivery(p_order_id text, p_photo_url text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set status = 'out_for_delivery', handoff_photo_url = p_photo_url
  where o.id = p_order_id
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
    and o.rental_item_id is null
    and o.status not in ('delivered','out_for_delivery')
    and (o.delivery_person_id is not null or o.self_delivery = true)
  returning o.*;
$function$;
CREATE OR REPLACE FUNCTION public.offer_order_to_rider(p_order_id text, p_rider_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set pending_rider_id = p_rider_id
  where o.id = p_order_id
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
    and o.rental_item_id is null
    and o.delivery_person_id is null
    and o.pending_rider_id is null
    and o.status is distinct from 'delivered'
    and exists (
      select 1 from orders o2
      where o2.business_id = o.business_id and o2.delivery_person_id = p_rider_id
        and o2.status = 'placed' and o2.id <> o.id
    )
  returning o.*;
$function$;
CREATE OR REPLACE FUNCTION public.accept_delivery_offer(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set
    delivery_person_id = o.pending_rider_id,
    delivery_person_name = (select d.name from delivery_persons d where d.id = o.pending_rider_id),
    pending_rider_id = null
  where o.id = p_order_id
    and o.pending_rider_id is not null
    and exists (select 1 from delivery_persons d where d.id = o.pending_rider_id and d.user_id = public.app_uid())
  returning o.*;
$function$;
CREATE OR REPLACE FUNCTION public.decline_delivery_offer(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set pending_rider_id = null
  where o.id = p_order_id
    and o.pending_rider_id is not null
    and exists (select 1 from delivery_persons d where d.id = o.pending_rider_id and d.user_id = public.app_uid())
  returning o.*;
$function$;
CREATE OR REPLACE FUNCTION public.apply_order_discount(p_order_id text, p_discount numeric)
 RETURNS SETOF orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_capped numeric;
begin
  select greatest(0, least(coalesce(p_discount,0), coalesce(o.items_total,0)))
    into v_capped
  from orders o where o.id = p_order_id;

  return query
    update orders o set
      discount_amount = v_capped,
      total = greatest(0, coalesce(o.items_total,0) - v_capped) + coalesce(o.delivery_fee,0) + coalesce(o.extra_delivery_fee,0)
    where o.id = p_order_id
      and o.rental_item_id is null
      and o.payment_status in ('pending_transfer','pending_cash')
      and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
    returning o.*;
end;
$function$;
CREATE OR REPLACE FUNCTION public.mark_order_ready_for_pickup(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set ready_for_pickup = true, self_delivery = false
  where o.id = p_order_id
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
    and o.rental_item_id is null
    and o.delivery_person_id is null
    and o.status is distinct from 'delivered' and o.status is distinct from 'declined'
    and (o.payment_method is distinct from 'swipe' or o.payment_status = 'paid')
  returning o.*;
$function$;
CREATE OR REPLACE FUNCTION public.mark_order_self_delivery(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set self_delivery = true, ready_for_pickup = false
  where o.id = p_order_id
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
    and o.rental_item_id is null
    and o.delivery_person_id is null
    and o.status is distinct from 'delivered' and o.status is distinct from 'declined'
    and (o.payment_method is distinct from 'swipe' or o.payment_status = 'paid')
  returning o.*;
$function$;
CREATE OR REPLACE FUNCTION public.submit_booking_slip(p_slip_keys jsonb, p_booking_id text, p_slip_enc text, p_slip_iv text)
 RETURNS SETOF rental_bookings
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ update rental_bookings set charge_status = 'slip_uploaded', slip_enc = p_slip_enc, slip_iv = p_slip_iv, slip_keys = p_slip_keys where id = p_booking_id and customer_id = public.app_uid() and status = 'accepted' and booking_charge is not null returning *; $function$;
CREATE OR REPLACE FUNCTION public.complete_auction_order(p_order_id text, p_delivery_zone text, p_payment_method text, p_delivery_target_type text DEFAULT 'person'::text, p_shipping_enc text DEFAULT NULL::text, p_shipping_iv text DEFAULT NULL::text, p_shipping_keys jsonb DEFAULT NULL::jsonb)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders set
    zone = p_delivery_zone,
    delivery_fee = case when delivery_type <> 'free' then case p_delivery_zone when 'hulhumale1' then 20 when 'hulhumale2' then 25 else 15 end else 0 end + coalesce(extra_delivery_fee, 0),
    delivery_partner_payout = case p_delivery_zone when 'hulhumale1' then 20 when 'hulhumale2' then 25 else 15 end,
    payment_method = p_payment_method,
    payment_status = case p_payment_method when 'transfer' then 'pending_transfer' when 'swipe' then 'awaiting_swipe' else 'pending_cash' end,
    delivery_target_type = p_delivery_target_type,
    receiver_name = null,
    receiver_phone = null,
    receiver_address = null,
    shipping_enc = p_shipping_enc,
    shipping_iv = p_shipping_iv,
    shipping_keys = p_shipping_keys
  where id = p_order_id and customer_id = public.app_uid() and payment_status = 'awaiting_completion'
    and p_payment_method in ('transfer','cash_on_pickup','swipe')
    and (p_payment_method <> 'swipe' or exists (select 1 from business_swipe_accounts s where s.business_id = orders.business_id))
    and exists (select 1 from auction_listings al where al.order_id = orders.id and al.current_highest_bidder = public.app_uid())
  returning *;
$function$;
CREATE OR REPLACE FUNCTION public.my_blocking_order()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select customer_checkout_blocked(public.app_uid());
$function$;
CREATE OR REPLACE FUNCTION public.set_delivery_charge(p_order_id text, p_amount numeric)
 RETURNS SETOF orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_amount is null or p_amount < 0 or p_amount > 10000 then
    raise exception 'invalid_delivery_charge' using errcode = 'P0001';
  end if;
  return query
    update orders o set
      delivery_fee = p_amount,
      total = greatest(0, coalesce(o.items_total,0) - coalesce(o.discount_amount,0))
              + p_amount + coalesce(o.extra_delivery_fee,0),
      payment_status = 'pending_transfer'
    where o.id = p_order_id
      and o.payment_status = 'awaiting_delivery_charge'
      and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
    returning o.*;
end;
$function$;
CREATE OR REPLACE FUNCTION public.cancel_order_before_payment(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set status = 'cancelled'
  where o.id = p_order_id
    and o.customer_id = public.app_uid()
    and o.status = 'placed'
    and o.delivery_person_id is null
    and o.pending_rider_id is null
    and o.payment_status in ('awaiting_delivery_charge','pending_transfer')
  returning o.*;
$function$;
CREATE OR REPLACE FUNCTION public.submit_transfer_slip(p_order_id text, p_slip_enc text, p_slip_iv text, p_slip_keys jsonb, p_amount numeric, p_account text)
 RETURNS SETOF orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_total numeric;
  v_acct  text;
begin
  select o.total, b.account_number into v_total, v_acct
  from orders o join businesses b on b.id = o.business_id
  where o.id = p_order_id and o.customer_id = public.app_uid();

  if v_total is null then
    return;  -- not the caller's order
  end if;
  if abs(coalesce(p_amount,-1) - v_total) > 0.01 then
    raise exception 'slip_amount_mismatch' using errcode = 'P0001';
  end if;
  if regexp_replace(coalesce(p_account,''), '\s', '', 'g')
       is distinct from regexp_replace(coalesce(v_acct,''), '\s', '', 'g') then
    raise exception 'slip_account_mismatch' using errcode = 'P0001';
  end if;

  return query
    update orders o set
      payment_status = 'slip_uploaded',
      payment_method = 'transfer',
      payment_review = case when o.payment_review = 'problem' then 'resubmitted' else o.payment_review end,
      slip_url = null,
      slip_enc = p_slip_enc, slip_iv = p_slip_iv, slip_keys = p_slip_keys
    where o.id = p_order_id
      and o.customer_id = public.app_uid()
      and (
        o.payment_status in ('pending_transfer','pending_cash')
        or (o.payment_status = 'slip_uploaded' and o.payment_review = 'problem')
      )
    returning o.*;
end;
$function$;
CREATE OR REPLACE FUNCTION public.flag_payment_problem(p_order_id text, p_reason text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders
  set payment_status = 'slip_uploaded',          -- reopens re-upload + rental gate
      payment_review = 'problem',
      payment_problem_reason = left(btrim(coalesce(p_reason,'')), 200)
  where id = p_order_id
    and payment_status in ('slip_uploaded','paid')
    and exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = public.app_uid())
  returning *;
$function$;
CREATE OR REPLACE FUNCTION public.set_business_swipe_account(p_business_id text, p_client_id text, p_client_secret text, p_webhook_secret text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from businesses b where b.id = p_business_id and b.owner_id = public.app_uid()) then
    return false;
  end if;
  if coalesce(trim(p_client_id),'') = '' or coalesce(trim(p_client_secret),'') = '' or coalesce(trim(p_webhook_secret),'') = '' then
    return false;
  end if;
  insert into business_swipe_accounts (business_id, client_id, client_secret, webhook_secret, updated_at)
  values (p_business_id, trim(p_client_id), trim(p_client_secret), trim(p_webhook_secret), now())
  on conflict (business_id) do update
    set client_id = excluded.client_id, client_secret = excluded.client_secret,
        webhook_secret = excluded.webhook_secret, updated_at = now();
  return true;
end;
$function$;
CREATE OR REPLACE FUNCTION public.approve_swipe_order(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set payment_status = 'awaiting_swipe'
  where o.id = p_order_id
    and o.payment_method = 'swipe' and o.payment_status = 'awaiting_approval'
    and o.status is distinct from 'declined'
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
    and exists (select 1 from business_swipe_accounts s where s.business_id = o.business_id)
  returning o.*;
$function$;
CREATE OR REPLACE FUNCTION public.decline_swipe_order(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set status = 'declined'
  where o.id = p_order_id
    and o.payment_method = 'swipe' and o.payment_status in ('awaiting_approval','awaiting_swipe')
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
  returning o.*;
$function$;
drop function if exists public.get_user_public_key(uuid);
create or replace function public.get_user_public_key(target_user_id text)
returns text language sql security definer set search_path = public
as $$ select public_key from user_profiles where user_id = target_user_id; $$;
grant execute on all functions in schema public to anon, authenticated;
commit;
