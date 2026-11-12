-- The super admin can manage any store's listings from Admin -> Stores ->
-- (store): approve, take down (admin_reject_items), feature (admin_feature_item)
-- and, with these two, pause / resume and delete.
create or replace function public.admin_set_items_paused(p_ids text[], p_paused boolean)
returns setof public.items
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin' using errcode = 'P0001'; end if;
  return query update items set paused = coalesce(p_paused, false) where id = any(p_ids) returning *;
end; $$;

-- Deletes what it can and returns the ids it deleted. Items the delete guard
-- refuses (an auction with bids, a rental with upcoming bookings) are skipped.
create or replace function public.admin_delete_items(p_ids text[])
returns setof text
language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  if not public.is_admin() then raise exception 'not_admin' using errcode = 'P0001'; end if;
  foreach v_id in array coalesce(p_ids, '{}') loop
    begin
      delete from items where id = v_id;
      if found then return next v_id; end if;
    exception when others then
      null;   -- in use: leave it
    end;
  end loop;
end; $$;

revoke all on function public.admin_set_items_paused(text[], boolean) from public;
revoke all on function public.admin_delete_items(text[]) from public;
grant execute on function public.admin_set_items_paused(text[], boolean) to anon, authenticated;
grant execute on function public.admin_delete_items(text[]) to anon, authenticated;
