-- Buy now orders can be paid by bank transfer, so a store can sell without
-- connecting Swipe. Flow (same approval step as Swipe):
--   placed (payment_method 'transfer', payment_status 'awaiting_approval')
--   -> store approves, setting the delivery charge for boat / island routes
--      (approve_transfer_order) -> 'pending_transfer'
--   -> customer pays and uploads the slip; amount and account number must
--      match (submit_transfer_slip, unchanged) -> 'slip_uploaded'
--   -> store approves the slip (approve_order_payment) -> 'paid'
--   The order goes to a rider only once it's paid.
-- Fee: Maldexpress takes 5% of a Buy now transfer order (no Swipe charge to
-- split), recorded when the store approves the slip, settled in Admin -> Fees.

-- 1. Customers may insert a Buy now order as transfer / awaiting_approval.
alter policy "customer insert own order" on public.orders with check (
  (public.app_uid() = customer_id)
  and swipe_reference is null and swipe_payment_link is null and paid_at is null
  and swipe_fee is null and platform_fee is null and platform_fee_due is null and fee_settled_at is null
  and (
    (rental_item_id is not null and (
         (payment_method = 'transfer' and payment_status = 'pending_transfer')
      or (payment_method = 'cash_on_pickup' and payment_status = 'pending_cash')
      or (payment_method = 'swipe' and payment_status = 'awaiting_swipe'
          and exists (select 1 from public.business_swipe_accounts s where s.business_id = orders.business_id))))
    or (rental_item_id is null and payment_status = 'awaiting_completion')
    or (rental_item_id is null and payment_method = 'swipe' and payment_status = 'awaiting_approval')
    or (rental_item_id is null and payment_method = 'transfer' and payment_status = 'awaiting_approval'
        and exists (select 1 from public.businesses b where b.id = orders.business_id and coalesce(trim(b.account_number),'') <> ''))
  )
);

-- 2. Store approves a transfer order (and sets the boat / island delivery charge).
create or replace function public.approve_transfer_order(p_order_id text, p_delivery_charge numeric default null)
returns setof public.orders language plpgsql security definer set search_path = public as $$
begin
  if p_delivery_charge is not null and (p_delivery_charge < 0 or p_delivery_charge > 10000) then
    raise exception 'invalid_delivery_charge' using errcode = 'P0001';
  end if;
  return query
    update orders o set
      payment_status = 'pending_transfer',
      delivery_fee = case when o.route in ('boat_to_island','local','boat_to_male') then p_delivery_charge else o.delivery_fee end,
      delivery_partner_payout = case when o.route in ('boat_to_island','local','boat_to_male') then p_delivery_charge else o.delivery_partner_payout end,
      total = case when o.route in ('boat_to_island','local','boat_to_male')
                   then greatest(0, coalesce(o.items_total,0) - coalesce(o.discount_amount,0)) + p_delivery_charge + coalesce(o.extra_delivery_fee,0)
                   else o.total end
    where o.id = p_order_id
      and o.payment_method = 'transfer' and o.payment_status = 'awaiting_approval'
      and o.rental_item_id is null
      and o.status is distinct from 'declined'
      and (o.route is null or o.route = 'male_zone' or p_delivery_charge is not null)
      and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
    returning o.*;
end;
$$;
grant execute on function public.approve_transfer_order(text, numeric) to anon, authenticated;

-- 3. Store declines / cancels a Buy now order before it's paid (Swipe or transfer).
create or replace function public.decline_order_request(p_order_id text)
returns setof public.orders language sql security definer set search_path = public as $$
  update orders o set status = 'declined'
  where o.id = p_order_id
    and (
      (o.payment_method = 'swipe' and o.payment_status in ('awaiting_approval','awaiting_swipe'))
      or (o.payment_method = 'transfer' and o.payment_status in ('awaiting_approval','pending_transfer')
          and o.rental_item_id is null
          and not exists (select 1 from auction_listings a where a.order_id = o.id))
    )
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
  returning o.*;
$$;
grant execute on function public.decline_order_request(text) to anon, authenticated;

-- 4. Slip approval records the 5% Maldexpress fee on Buy now transfer orders.
--    Everything else (rentals, auction wins, cash) is unchanged.
create or replace function public.approve_order_payment(p_order_id text)
returns setof public.orders language sql security definer set search_path = public as $$
  update orders o
  set payment_status = 'paid', payment_review = 'approved', payment_problem_reason = null,
      paid_at = case when o.payment_method = 'transfer' and o.rental_item_id is null
                      and not exists (select 1 from auction_listings a where a.order_id = o.id)
                     then coalesce(o.paid_at, now()) else o.paid_at end,
      swipe_fee = case when o.payment_method = 'transfer' and o.rental_item_id is null
                        and not exists (select 1 from auction_listings a where a.order_id = o.id)
                       then 0 else o.swipe_fee end,
      platform_fee = case when o.payment_method = 'transfer' and o.rental_item_id is null
                           and not exists (select 1 from auction_listings a where a.order_id = o.id)
                          then round(coalesce(o.total,0) * 0.05, 2) else o.platform_fee end,
      platform_fee_due = case when o.payment_method = 'transfer' and o.rental_item_id is null
                               and not exists (select 1 from auction_listings a where a.order_id = o.id)
                              then round(coalesce(o.total,0) * 0.05, 2) else o.platform_fee_due end
  where o.id = p_order_id
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
  returning o.*;
$$;
