-- Security fixes from the 2026-11-11 audit.

-- (2) Transfer slips are checked by the server: the order must be waiting for
--     a transfer (store already approved it), and the amount and account
--     number on the slip must match the order total and the store's account.
create or replace function public.submit_transfer_slip(p_order_id text, p_slip_url text, p_amount numeric, p_account text)
returns setof public.orders language plpgsql security definer set search_path = public as $$
declare v_total numeric; v_acct text;
begin
  select o.total, b.account_number into v_total, v_acct
    from orders o join businesses b on b.id = o.business_id
   where o.id = p_order_id and o.customer_id = public.app_uid();
  if v_total is null then return; end if;
  if abs(coalesce(p_amount,-1) - v_total) > 0.01 then raise exception 'slip_amount_mismatch' using errcode = 'P0001'; end if;
  if regexp_replace(coalesce(p_account,''), '\s', '', 'g') is distinct from regexp_replace(coalesce(v_acct,''), '\s', '', 'g') then
    raise exception 'slip_account_mismatch' using errcode = 'P0001';
  end if;
  if coalesce(p_slip_url,'') = '' then raise exception 'slip_missing' using errcode = 'P0001'; end if;
  return query
    update orders o set
      payment_status = 'slip_uploaded', payment_method = 'transfer', slip_url = p_slip_url,
      payment_review = case when o.payment_review = 'problem' then 'resubmitted' else o.payment_review end
    where o.id = p_order_id and o.customer_id = public.app_uid()
      and o.status not in ('declined','cancelled')
      and (o.payment_status in ('pending_transfer','pending_cash') or (o.payment_status = 'slip_uploaded' and o.payment_review = 'problem'))
    returning o.*;
end; $$;
grant execute on function public.submit_transfer_slip(text, text, numeric, text) to anon, authenticated;
-- The old unchecked version is retired (an old cached app gets a clear error).
create or replace function public.submit_transfer_slip(p_order_id text, p_slip_url text)
returns setof public.orders language plpgsql security definer set search_path = public as $$
begin raise exception 'app_update_required' using errcode = 'P0001'; end; $$;

-- (3) Phone -> email lookup is no longer open to the public. Sign-in and
--     password reset by mobile number go through the phone-login edge
--     function (service role), which only answers with the email once the
--     password is right, and sends reset emails itself.
revoke execute on function public.resolve_login_email(text) from anon, authenticated, public;

-- (4) Riders only see waiting jobs they could take: from stores on their
--     own island (Greater Malé counts as one area), or, while online with a
--     fresh GPS fix, from stores within 20 km. Not every waiting order.
create or replace function public.rider_can_see_open_order(p_business_id text, p_is_rental boolean, p_ready boolean, p_needs_partner boolean)
returns boolean language sql stable security definer set search_path = public as $$
  select (case when p_is_rental then coalesce(p_needs_partner,false) else coalesce(p_ready,false) end)
     and exists (
       select 1 from delivery_persons d, businesses b
        where d.user_id = public.app_uid() and b.id = p_business_id
          and (
            (coalesce(b.island,'Malé') in ('Malé','Hulhumalé','Villimalé') and coalesce(d.island,'Malé') in ('Malé','Hulhumalé','Villimalé'))
            or coalesce(b.island,'Malé') = coalesce(d.island,'Malé')
            or (d.online and d.lat is not null and d.lng is not null and b.lat is not null and b.lng is not null
                and d.location_updated_at > now() - interval '30 minutes'
                and 2 * 6371 * asin(sqrt(power(sin(radians(b.lat - d.lat)/2),2) + cos(radians(d.lat)) * cos(radians(b.lat)) * power(sin(radians(b.lng - d.lng)/2),2))) <= 20)
          )
     );
$$;
grant execute on function public.rider_can_see_open_order(text, boolean, boolean, boolean) to anon, authenticated;

alter policy "read own or relevant orders" on public.orders using (
  ((select public.app_uid()) = customer_id)
  or exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = (select public.app_uid()))
  or exists (select 1 from delivery_persons d where d.id = orders.delivery_person_id and d.user_id = (select public.app_uid()))
  or exists (select 1 from delivery_persons d where d.id = orders.pending_rider_id and d.user_id = (select public.app_uid()))
  or (orders.delivery_person_id is null and orders.status is distinct from 'delivered'
      and public.rider_can_see_open_order(orders.business_id, orders.rental_item_id is not null, orders.ready_for_pickup, orders.needs_delivery_partner))
);
alter policy "update own or relevant orders" on public.orders using (
  exists (select 1 from businesses b where b.id = orders.business_id and b.owner_id = (select public.app_uid()))
  or ((select public.app_uid()) = customer_id)
  or (orders.delivery_person_id is null and orders.ready_for_pickup = true
      and public.rider_can_see_open_order(orders.business_id, orders.rental_item_id is not null, orders.ready_for_pickup, orders.needs_delivery_partner))
  or exists (select 1 from delivery_persons d where d.id = orders.delivery_person_id and d.user_id = (select public.app_uid()))
);

-- (5) Swipe stays hidden in the app until the admin switches it on (after
--     the Swipe server keys are added).
alter table public.platform_settings add column if not exists swipe_enabled boolean not null default false;
notify pgrst, 'reload schema';
