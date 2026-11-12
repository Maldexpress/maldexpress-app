-- Contact details stay private until there's an order between the people.
--
-- 1. A store's phone number is no longer readable by everyone. The columns a
--    shopper needs (name, island, rating, ...) stay public; phone comes from
--    business_contacts(), only for: the store's owner, the admin, a customer
--    who has an order or rental booking with that store, and a rider on one of
--    its orders. (A column added to businesses later must be granted here too.)
-- 2. Rider profiles (name, phone, location) are no longer readable by
--    everyone: a rider sees their own, the admin sees all, and a store or a
--    customer sees a rider only once that rider is on (or offered) one of
--    their orders.
-- Customers were already private (user_profiles / customer_addresses are
-- owner-only; a store sees customer details only on its own orders).

revoke select on public.businesses from anon, authenticated;
grant select (id, owner_id, name, owner_name, account_number, account_name, tier, join_date, paid_at,
              category, category_other_name, rating, address, island, lat, lng)
  on public.businesses to anon, authenticated;

create or replace function public.business_contacts()
returns table(business_id text, phone text)
language sql stable security definer set search_path = public as $$
  select b.id, b.phone from businesses b
   where public.app_uid() is not null and (
         b.owner_id = public.app_uid()
      or public.is_admin()
      or exists (select 1 from orders o where o.business_id = b.id and o.customer_id = public.app_uid())
      or exists (select 1 from rental_bookings k where k.business_id = b.id and k.customer_id = public.app_uid())
      or exists (select 1 from orders o join delivery_persons d on d.id in (o.delivery_person_id, o.pending_rider_id)
                  where o.business_id = b.id and d.user_id = public.app_uid()));
$$;
revoke all on function public.business_contacts() from public;
grant execute on function public.business_contacts() to anon, authenticated;

create or replace function public.can_see_rider(p_rider_id text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.app_uid() is not null and (
       public.is_admin()
    or exists (select 1 from delivery_persons d where d.id = p_rider_id and d.user_id = public.app_uid())
    or exists (select 1 from orders o
                where (o.delivery_person_id = p_rider_id or o.pending_rider_id = p_rider_id)
                  and (o.customer_id = public.app_uid()
                       or exists (select 1 from businesses b where b.id = o.business_id and b.owner_id = public.app_uid()))));
$$;
drop policy if exists "public read delivery" on public.delivery_persons;
drop policy if exists "read riders you work with" on public.delivery_persons;
create policy "read riders you work with" on public.delivery_persons for select to anon, authenticated
  using (user_id = public.app_uid() or public.can_see_rider(id));
