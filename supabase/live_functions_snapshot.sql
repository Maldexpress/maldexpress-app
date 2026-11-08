-- Snapshot of the public-schema functions on the live Maldexpress Supabase
-- project (jbzyphtrcgrfnleocusp), read on 2026-11-08. Several of these
-- (payment review, delivery charges, checkout blocking, the order guard
-- triggers) were applied directly in Supabase and never committed here.
-- Reference only: do not run this file as a migration.

-- ===== accept_delivery_offer
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
    and exists (select 1 from delivery_persons d where d.id = o.pending_rider_id and d.user_id = auth.uid())
  returning o.*;
$function$;

-- ===== apply_order_discount
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
      and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = auth.uid())
    returning o.*;
end;
$function$;

-- ===== approve_order_payment
CREATE OR REPLACE FUNCTION public.approve_order_payment(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders
  set payment_status = 'paid', payment_review = 'approved', payment_problem_reason = null
  where id = p_order_id
    and exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = auth.uid())
  returning *;
$function$;

-- ===== bids_block_guard
CREATE OR REPLACE FUNCTION public.bids_block_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_block text;
begin
  v_block := customer_checkout_blocked(NEW.bidder_id);
  if v_block is not null then
    raise exception 'checkout_blocked:%', v_block using errcode = 'P0001';
  end if;
  return NEW;
end;
$function$;

-- ===== bookings_block_guard
CREATE OR REPLACE FUNCTION public.bookings_block_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_block text;
begin
  v_block := customer_checkout_blocked(NEW.customer_id);
  if v_block is not null then
    raise exception 'checkout_blocked:%', v_block using errcode = 'P0001';
  end if;
  return NEW;
end;
$function$;

-- ===== cancel_booking_request
CREATE OR REPLACE FUNCTION public.cancel_booking_request(p_booking_id text)
 RETURNS SETOF rental_bookings
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update rental_bookings
  set status = 'cancelled'
  where id = p_booking_id and customer_id = auth.uid() and status = 'pending'
  returning *;
$function$;

-- ===== cancel_order_before_payment
CREATE OR REPLACE FUNCTION public.cancel_order_before_payment(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set status = 'cancelled'
  where o.id = p_order_id
    and o.customer_id = auth.uid()
    and o.status = 'placed'
    and o.delivery_person_id is null
    and o.pending_rider_id is null
    and o.payment_status in ('awaiting_delivery_charge','pending_transfer')
  returning o.*;
$function$;

-- ===== claim_rental_job
CREATE OR REPLACE FUNCTION public.claim_rental_job(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rider_id text; v_rider_name text;
begin
  select id, name into v_rider_id, v_rider_name from delivery_persons where user_id = auth.uid();
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

-- ===== complete_auction_order
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
    payment_status = case when p_payment_method = 'transfer' then 'pending_transfer' else 'pending_cash' end,
    delivery_target_type = p_delivery_target_type,
    receiver_name = null,
    receiver_phone = null,
    receiver_address = null,
    shipping_enc = p_shipping_enc,
    shipping_iv = p_shipping_iv,
    shipping_keys = p_shipping_keys
  where id = p_order_id and customer_id = auth.uid() and payment_status = 'awaiting_completion'
    and exists (select 1 from auction_listings al where al.order_id = orders.id and al.current_highest_bidder = auth.uid())
  returning *;
$function$;

-- ===== confirm_cash_received
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
      exists (select 1 from delivery_persons d where d.id = o.delivery_person_id and d.user_id = auth.uid())
      or (o.self_delivery = true and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = auth.uid()))
    )
  returning o.*;
$function$;

-- ===== customer_checkout_blocked
CREATE OR REPLACE FUNCTION public.customer_checkout_blocked(p_uid uuid DEFAULT auth.uid())
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

-- ===== decline_delivery_offer
CREATE OR REPLACE FUNCTION public.decline_delivery_offer(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set pending_rider_id = null
  where o.id = p_order_id
    and o.pending_rider_id is not null
    and exists (select 1 from delivery_persons d where d.id = o.pending_rider_id and d.user_id = auth.uid())
  returning o.*;
$function$;

-- ===== decrement_rental_stock
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
    and auth.uid() is not null
  returning *;
$function$;

-- ===== flag_payment_problem
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
    and exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = auth.uid())
  returning *;
$function$;

-- ===== get_delivery_pool_private_key
CREATE OR REPLACE FUNCTION public.get_delivery_pool_private_key()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from delivery_persons where user_id = auth.uid()) then
    raise exception 'not a delivery partner';
  end if;
  return 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC5Ac/MJNziyZX+VN6NCf7cehjefhxLqvfrwD+wwH4gtj7OaKMMLVcKngqBi+OtERQ39TddUppvwS6Tiv29wXkbcRhgBMKGnAg0z3514wU1WsgoCLzvM6CwzAlRsO9Pl6n3ujG4BJDrbdrGMMeW9kTGUsE85Ehug9foSsow7O9B/4t5af88LpEP2I032/t0C+drAMVWuw/jriGStcvxRM3m6BSd8IKIIls9JXTF+Uwc0E6wJ7OsoW6dhNXT4MrTrd63p2mRuDyvTCPPJiphOFFwqrohdh/7SUbmKht2Bu7HE7p4VUjfIwnMQSAjPo7tfnaZZ0fdbp4Teikd/ajacntTAgMBAAECggEAMkSiwHY3qktZvPw0aCASJrfqL/IWIB05Nc5Lv+vdmWfLUuwteS6Mmu7sLdzjpO+iDb5MJ8g8/CaCUEaQwVFjZahqFhTVAhw9QpQqaT+g96lN/0q4g0oE3GTkF1U7AOZVoWDvB2/+LGnx6q3wXT1W3Ig5xyDD6XtbW9uOapLGQ6kDEgk3hgbBi9VwyMfmwwkYFcWyzdIQ4fW2nkfdvj41a5VeH++qEl0yTS66p6d9kFm3C7nR9yb1u5BGSDKhEKZINkg4vM+vkKDI0sTTan7RaOsmHq4ILZWjz4GR6FpgGhL+30X++sqW7PKXAuAqhDBl6DTWpeqqyYaKPJr0vAOBOQKBgQD8/arMlk/1Qo8QOFWWYXQYAezu0c388elXd9kiAqHA5zNWohMxyUDtwGh6YWOMnTamqrk5+ZAQO6YYd31HVb9o/wxEoQ01xVweLm9iEi2GhNKh+zd/AwKfC2CR+LgjqWmBNU8rwfrwnTq1qZbIw1zG71oUv/Yl1/9pa3bwO9rKTwKBgQC7NSPwfABmMsUhauC6ZbRyOYm3RZ1KF3+EDIlAc4EG2UfyKmsQ+L3Z2dMiaUUB2QC6rOde5v8RuFCpBqKM3H6HBavoKAZ/mVMC3AzhP0SWR17UQJR43YKDYTNpv2Ckb94b2AluV+tGqa1ExhAvG2H2KEPuvqAJpYPPMWjI4S4xvQKBgDvdetE2sG0E9v2LlxUismoL6pkIpIm6ZNEB1yupG8Wd8BQL/ibFzMt1wENVUE0x1oDR3UrOtzxgIQmhHNAIhma+E5UZ1xpmPUoXCtxWGNfADmeuHo+7kp83/f4MsOYfbIvapYVhPZQ6YG4kVz3inM2mTdajJggGeLXlbBukzj0ZAoGAHXziW1f87BwlJv1hxpqMkM11XtPtUaVf5Znf6LII6d5B0ehSkwrLRMxl0G7Ket8GmWDw1OcH2G+y7Nzpr8xvda80A86CL4kkJTgqIzTHBfDaBA7kFCG4FB+0bHzDqUMhtjsSSTo6Chhh/YpBNFpY1OBEyw9lv/89Qt6ihbnKf/UCgYEA4umpTGogv/Lu9rmDH7wnu/Scx4leJ2HOLjXoqx3R1jaztkUa/gAa8RJrhIDU35sc03qL8u+xap08yzgO7is9mI3OSZBUUoWjQOoMZXlzqvN1KU2RgO+ru6QKOgkwjx5rSBA0IeEzd0PFld2U3qIpox0RsYnNIJVkA+Rcwe/fZok=';
end;
$function$;

-- ===== get_user_public_key
CREATE OR REPLACE FUNCTION public.get_user_public_key(target_user_id uuid)
 RETURNS text
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public_key from user_profiles where user_id = target_user_id;
$function$;

-- ===== is_admin
CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select exists(select 1 from admins where user_id = auth.uid()); $function$;

-- ===== mark_delivered
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
    and exists (select 1 from delivery_persons d where d.id = orders.delivery_person_id and d.user_id = auth.uid())
  returning *;
$function$;

-- ===== mark_order_delivered_by_business
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
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = auth.uid())
    and o.self_delivery = true
    and o.status = 'out_for_delivery'
    and (o.delivery_target_type is distinct from 'boat' or p_boat_photo_url is not null)
  returning o.*;
$function$;

-- ===== mark_order_out_for_delivery
CREATE OR REPLACE FUNCTION public.mark_order_out_for_delivery(p_order_id text, p_photo_url text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set status = 'out_for_delivery', handoff_photo_url = p_photo_url
  where o.id = p_order_id
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = auth.uid())
    and o.rental_item_id is null
    and o.status not in ('delivered','out_for_delivery')
    and (o.delivery_person_id is not null or o.self_delivery = true)
  returning o.*;
$function$;

-- ===== mark_order_ready_for_pickup
CREATE OR REPLACE FUNCTION public.mark_order_ready_for_pickup(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set ready_for_pickup = true, self_delivery = false
  where o.id = p_order_id
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = auth.uid())
    and o.rental_item_id is null
    and o.delivery_person_id is null
    and o.status is distinct from 'delivered'
  returning o.*;
$function$;

-- ===== mark_order_self_delivery
CREATE OR REPLACE FUNCTION public.mark_order_self_delivery(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set self_delivery = true, ready_for_pickup = false
  where o.id = p_order_id
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = auth.uid())
    and o.rental_item_id is null
    and o.delivery_person_id is null
    and o.status is distinct from 'delivered'
  returning o.*;
$function$;

-- ===== mark_payout_paid
CREATE OR REPLACE FUNCTION public.mark_payout_paid(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders
  set payout_status = 'settled'
  where id = p_order_id
    and exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = auth.uid())
  returning *;
$function$;

-- ===== mark_rental_fulfilled
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
    and exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = auth.uid())
  returning *;
$function$;

-- ===== mark_rental_returned
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
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = auth.uid())
  returning o.* into v_result;

  if v_result.id is null then
    return;
  end if;

  update items set stock = stock + 1 where id = v_result.rental_item_id;

  return query select v_result.*;
end;
$function$;

-- ===== my_blocking_order
CREATE OR REPLACE FUNCTION public.my_blocking_order()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select customer_checkout_blocked(auth.uid());
$function$;

-- ===== offer_order_to_rider
CREATE OR REPLACE FUNCTION public.offer_order_to_rider(p_order_id text, p_rider_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders o set pending_rider_id = p_rider_id
  where o.id = p_order_id
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = auth.uid())
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

-- ===== offer_rental_delivery
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
    and exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = auth.uid())
  returning *;
$function$;

-- ===== orders_insert_guard
CREATE OR REPLACE FUNCTION public.orders_insert_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_block text;
begin
  if NEW.payment_status = 'pending_cash'
     and NEW.payment_method is distinct from 'cash_on_pickup' then
    raise exception 'cash_not_supported' using errcode = 'P0001';
  end if;
  if NEW.payment_status is distinct from 'awaiting_completion' then
    v_block := customer_checkout_blocked(NEW.customer_id);
    if v_block is not null then
      raise exception 'checkout_blocked:%', v_block using errcode = 'P0001';
    end if;
  end if;
  return NEW;
end;
$function$;

-- ===== orders_update_guard
CREATE OR REPLACE FUNCTION public.orders_update_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_block text;
begin
  -- No switching an order INTO cash-to-delivery-person (legacy in-flight cash
  -- orders can still move pending_cash -> cash_collected and finish; rental
  -- cash-to-store orders are allowed).
  if NEW.payment_status = 'pending_cash'
     and OLD.payment_status is distinct from 'pending_cash'
     and NEW.payment_method is distinct from 'cash_on_pickup' then
    raise exception 'cash_not_supported' using errcode = 'P0001';
  end if;

  -- Winner completing an auction order counts as checkout.
  if OLD.payment_status = 'awaiting_completion' and NEW.payment_status is distinct from 'awaiting_completion' then
    v_block := customer_checkout_blocked(OLD.customer_id);
    if v_block is not null then
      raise exception 'checkout_blocked:%', v_block using errcode = 'P0001';
    end if;
  end if;

  -- A rider can't be requested / the order can't go out until the business
  -- has typed the delivery charge (manual-charge items).
  if NEW.payment_status = 'awaiting_delivery_charge' and (
       (NEW.ready_for_pickup and not coalesce(OLD.ready_for_pickup,false))
    or (NEW.status = 'out_for_delivery' and OLD.status is distinct from 'out_for_delivery')
    or (NEW.self_delivery and not coalesce(OLD.self_delivery,false))
  ) then
    raise exception 'delivery_charge_required' using errcode = 'P0001';
  end if;

  -- The business always pays the rider now, so every delivered (non-rental)
  -- order opens a pending payout. Rentals keep their own payout timing.
  if NEW.status = 'delivered' and OLD.status is distinct from 'delivered'
     and NEW.payout_status is null and NEW.rental_item_id is null then
    NEW.payout_status := 'pending';
  end if;

  return NEW;
end;
$function$;

-- ===== place_bid
CREATE OR REPLACE FUNCTION public.place_bid(p_auction_id text, p_bid_amount numeric)
 RETURNS SETOF auction_listings
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with updated as (
    update auction_listings
    set current_highest_bid = p_bid_amount, current_highest_bidder = auth.uid(), bid_count = coalesce(bid_count,0) + 1
    where id = p_auction_id
      and status = 'active'
      and end_time > now()
      and auth.uid() is not null
      and not exists (select 1 from businesses b where b.id = auction_listings.business_id and b.owner_id = auth.uid())
      and (
        (current_highest_bid is null and p_bid_amount >= starting_price)
        or (current_highest_bid is not null and p_bid_amount >= current_highest_bid + bid_increment)
      )
    returning *
  ),
  ins as (
    insert into auction_bids (id, auction_id, bidder_id, bid_amount)
    select 'bid_' || replace(gen_random_uuid()::text, '-', ''), p_auction_id, auth.uid(), p_bid_amount
    from updated
    returning 1
  )
  select * from updated;
$function$;

-- ===== resolve_login_email
CREATE OR REPLACE FUNCTION public.resolve_login_email(p_phone text)
 RETURNS text
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select email from user_profiles where phone = p_phone limit 1;
$function$;

-- ===== set_default_address
CREATE OR REPLACE FUNCTION public.set_default_address(p_address_id text, p_category text)
 RETURNS SETOF customer_addresses
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with unset as (
    update customer_addresses set is_default = false
    where customer_id = auth.uid() and category = p_category and is_default = true
  )
  update customer_addresses set is_default = true
  where id = p_address_id and customer_id = auth.uid() and category = p_category
  returning *;
$function$;

-- ===== set_delivery_charge
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
      and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = auth.uid())
    returning o.*;
end;
$function$;

-- ===== settle_payout
CREATE OR REPLACE FUNCTION public.settle_payout(p_order_id text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders
  set payment_status = 'settled'
  where id = p_order_id
    and exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = auth.uid())
  returning *;
$function$;

-- ===== submit_booking_slip
CREATE OR REPLACE FUNCTION public.submit_booking_slip(p_slip_keys jsonb, p_booking_id text, p_slip_enc text, p_slip_iv text)
 RETURNS SETOF rental_bookings
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ update rental_bookings set charge_status = 'slip_uploaded', slip_enc = p_slip_enc, slip_iv = p_slip_iv, slip_keys = p_slip_keys where id = p_booking_id and customer_id = auth.uid() and status = 'accepted' and booking_charge is not null returning *; $function$;

-- ===== submit_transfer_slip
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
  where o.id = p_order_id and o.customer_id = auth.uid();

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
      and o.customer_id = auth.uid()
      and (
        o.payment_status in ('pending_transfer','pending_cash')
        or (o.payment_status = 'slip_uploaded' and o.payment_review = 'problem')
      )
    returning o.*;
end;
$function$;

-- ===== submit_transfer_slip
CREATE OR REPLACE FUNCTION public.submit_transfer_slip(p_order_id text, p_slip_url text)
 RETURNS SETOF orders
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update orders
  set payment_status = 'slip_uploaded', slip_url = p_slip_url, payment_method = 'transfer'
  where id = p_order_id and customer_id = auth.uid()
  returning *;
$function$;
