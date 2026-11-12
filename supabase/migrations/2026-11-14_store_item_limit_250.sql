-- Every store can list up to 250 items (was 150). Same trigger, new number;
-- the app's STORE_ITEM_LIMIT says the same.
create or replace function public.items_store_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from items where business_id = NEW.business_id) >= 250 then
    raise exception 'item_limit_reached';
  end if;
  return NEW;
end; $$;
