-- Listing is free for every store, up to 150 items (no trial, no Pro tier).
-- The app checks the same limit (STORE_ITEM_LIMIT); this stops it being
-- bypassed. Items already over the limit stay; only new ones are refused.
create or replace function public.items_store_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from items where business_id = NEW.business_id) >= 150 then
    raise exception 'item_limit_reached';
  end if;
  return NEW;
end; $$;
drop trigger if exists items_store_limit on public.items;
create trigger items_store_limit before insert on public.items
  for each row execute function public.items_store_limit();
