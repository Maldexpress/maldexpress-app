-- One photo, one item. The app stores a small fingerprint of every item photo
-- (items.photo_prints, same order as items.images; computed in the browser
-- from the picture itself, so the same photo resized or re-saved still
-- matches). A store can't save an item whose photos are already on another
-- of its items. Names: the app warns about, and can replace, an item with
-- the same name in the same store.
alter table public.items add column if not exists photo_prints text[];

create or replace function public.items_photo_unique() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if NEW.photo_prints is null or cardinality(NEW.photo_prints) = 0 then return NEW; end if;
  if TG_OP = 'UPDATE' and NEW.photo_prints is not distinct from OLD.photo_prints then return NEW; end if;
  select i.name into v_name from items i
   where i.business_id = NEW.business_id and i.id <> NEW.id
     and i.photo_prints && array_remove(NEW.photo_prints, null)
   limit 1;
  if v_name is not null then
    raise exception 'photo_in_use:%', v_name using errcode = 'P0001';
  end if;
  return NEW;
end; $$;
drop trigger if exists items_photo_unique on public.items;
create trigger items_photo_unique before insert or update of photo_prints on public.items
  for each row execute function public.items_photo_unique();
