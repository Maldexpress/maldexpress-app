-- Bestsellers: units sold per item THROUGH THE APP.
-- A sale counts only when the order was placed in the app, paid in the app
-- (Swipe paid by its webhook, or a bank transfer whose slip was uploaded in the
-- app and confirmed by the store; slip_confirmed_at is stamped by
-- orders_slip_confirmed) and delivered. Deals made outside the app, cash and
-- rentals don't count. Customers can only read their own orders, so this
-- security-definer function returns just the totals per item, nothing else.
create or replace function public.item_sales()
returns table(item_id text, units bigint)
language sql stable security definer set search_path = public as $$
  select l->>'itemId' as item_id, sum(greatest(coalesce((l->>'qty')::int, 1), 0))::bigint as units
  from public.orders o
  cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) l
  where o.status = 'delivered'
    and o.rental_item_id is null
    and o.payment_status in ('paid','settled')
    and ( o.payment_method = 'swipe'
          or (o.payment_method = 'transfer' and o.slip_confirmed_at is not null) )
    and l ? 'itemId'
  group by l->>'itemId';
$$;
revoke all on function public.item_sales() from public;
grant execute on function public.item_sales() to anon, authenticated;
