-- A small first batch of items for Home, so the shop front can be drawn
-- before the whole catalogue has downloaded (the app fetches the rest in the
-- background and tops Home up). Up to p_per items per listing type and
-- category, chosen at random, plus every item that is featured right now and
-- every item that has sold in the app (those lead Home).
-- Security invoker: the items read policy still decides what a caller sees,
-- so customers only ever get approved, unpaused items.
create or replace function public.home_sample(p_per integer default 20)
returns setof public.items
language sql stable security invoker set search_path = public as $$
  with ranked as (
    select i.id,
           row_number() over (partition by coalesce(i.listing_type,'buy_now'), coalesce(i.category,'Other') order by random()) as rn
      from items i
     where i.approval_status = 'approved' and not coalesce(i.paused, false)
  )
  select i.*
    from items i
    join ranked r on r.id = i.id
   where r.rn <= greatest(1, least(coalesce(p_per, 20), 60))
      or (i.featured_until is not null and i.featured_until > now())
      or i.id in (select s.item_id from item_sales() s);
$$;

grant execute on function public.home_sample(integer) to anon, authenticated;
