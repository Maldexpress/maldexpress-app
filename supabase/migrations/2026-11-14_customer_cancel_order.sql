-- A customer can cancel their own Buy now order any time before they pay:
-- while the store hasn't confirmed it yet (awaiting_approval), or after it
-- confirmed but before payment (awaiting_swipe / pending_transfer). Once a
-- slip is uploaded or Swipe has taken the money it can't be cancelled here.
-- A cancelled order ends like a declined one (status 'declined'), with
-- cancelled_at set so both sides see who cancelled it.
alter table public.orders add column if not exists cancelled_at timestamptz;

create or replace function public.cancel_order_by_customer(p_order_id text)
returns setof public.orders
language sql security definer set search_path = public as $$
  update orders o set status = 'declined', cancelled_at = now()
  where o.id = p_order_id
    and o.customer_id = public.app_uid()
    and o.status is distinct from 'declined'
    and o.rental_item_id is null
    and not exists (select 1 from auction_listings a where a.order_id = o.id)
    and (
      (o.payment_method = 'swipe'    and o.payment_status in ('awaiting_approval','awaiting_swipe'))
      or (o.payment_method = 'transfer' and o.payment_status in ('awaiting_approval','pending_transfer'))
    )
  returning o.*;
$$;
revoke all on function public.cancel_order_by_customer(text) from public;
grant execute on function public.cancel_order_by_customer(text) to anon, authenticated;
