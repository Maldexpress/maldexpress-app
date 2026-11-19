-- A store's own logo (profile picture), set in Register your business and in
-- Store settings. A public photo URL uploaded through upload-item-photo; NULL =
-- the store's initial on a coloured circle. Owners already update their own
-- row (businesses RLS), so no policy changes.
alter table public.businesses add column if not exists logo_url text;
comment on column public.businesses.logo_url is 'Store logo (public photo URL), shown on the store page, store lists and item pages.';
