-- A store can deliver a Buy now order before the customer has paid (it takes
-- the risk), and a customer with a delivered order they haven't paid for
-- can't place a new order until they pay it.

-- 1. Store marks an approved but unpaid order as delivered (it delivers it
--    itself; no rider is involved, so no rider payout is opened).
create or replace function public.mark_unpaid_order_delivered(p_order_id text)
returns setof public.orders
language sql security definer set search_path = public as $$
  update orders o set status = 'delivered', self_delivery = true, ready_for_pickup = false
  where o.id = p_order_id
    and exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid())
    and o.rental_item_id is null
    and not exists (select 1 from auction_listings a where a.order_id = o.id)
    and o.delivery_person_id is null
    and o.status is distinct from 'delivered' and o.status is distinct from 'declined'
    and o.payment_status in ('pending_transfer','awaiting_swipe')
  returning o.*;
$$;
revoke all on function public.mark_unpaid_order_delivered(text) from public;
grant execute on function public.mark_unpaid_order_delivered(text) to anon, authenticated;

-- 2. Checkout block also covers a delivered order still waiting for Swipe.
--    (Same as the live function, plus 'awaiting_swipe'.)
create or replace function public.customer_checkout_blocked(p_uid text default public.app_uid())
returns text
language sql stable security definer set search_path = public as $$
  select o.id
  from orders o
  where o.customer_id = p_uid
    and o.status = 'delivered'
    and (
      o.payment_review in ('problem','resubmitted')
      or (o.payment_review is distinct from 'approved'
          and o.payment_status in ('pending_transfer','pending_cash','awaiting_swipe'))
    )
  order by o.created_at
  limit 1;
$$;
