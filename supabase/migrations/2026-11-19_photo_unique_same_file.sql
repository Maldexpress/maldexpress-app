-- Photo rule: block only a photo whose FILE is identical to one already on a
-- different item of the same store.
--
-- Before: items_photo_unique compared items.photo_prints, a visual fingerprint
-- the browser works out from the picture. Equal fingerprints were treated as
-- the same photo. Because the app could only load the first 1000 items
-- (PostgREST max_rows), Upload a list didn't know about items saved earlier
-- and inserted them again under new ids; their photos then matched their own
-- earlier copies and the whole save was refused with
-- "photo_in_use:<that same item's name>".
--
-- Now:
--  * items.photo_hashes text[] holds a SHA-256 of each photo file's bytes
--    (same order as images), sent by the app. Byte-identical files are the
--    only thing the server refuses.
--  * A match with another item that has the same name (ignoring case, accents
--    and punctuation, like the app's nameKey) is the same product uploaded
--    again, not a duplicate, so it is let through.
--  * photo_prints stays for the app's own "looks the same" warning in the
--    preview, which the store can override; the server no longer enforces it.
-- No existing item or photo is changed or deleted.

alter table public.items add column if not exists photo_hashes text[];
comment on column public.items.photo_hashes is
  'SHA-256 (hex) of each photo file, same order as images. Used by items_photo_unique.';

create or replace function public.item_name_key(t text) returns text
language sql immutable set search_path = public as $$
  select btrim(regexp_replace(lower(translate(coalesce(t, ''),
    'ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖòóôõöÙÚÛÜùúûüÝýÿÑñÇç',
    'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuYyyNnCc')), '[^a-z0-9]+', ' ', 'g'));
$$;

create or replace function public.items_photo_unique() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_name text; v_hashes text[];
begin
  v_hashes := array_remove(NEW.photo_hashes, null);
  if v_hashes is null or cardinality(v_hashes) = 0 then return NEW; end if;
  if TG_OP = 'UPDATE' and NEW.photo_hashes is not distinct from OLD.photo_hashes then return NEW; end if;
  select i.name into v_name from items i
   where i.business_id = NEW.business_id
     and i.id <> NEW.id
     and i.photo_hashes && v_hashes
     and public.item_name_key(i.name) <> public.item_name_key(NEW.name)
   limit 1;
  if v_name is not null then
    raise exception 'photo_in_use:%', v_name using errcode = 'P0001';
  end if;
  return NEW;
end; $$;

drop trigger if exists items_photo_unique on public.items;
create trigger items_photo_unique before insert or update of photo_hashes, name on public.items
  for each row execute function public.items_photo_unique();

create index if not exists items_photo_hashes_gin on public.items using gin (photo_hashes);
