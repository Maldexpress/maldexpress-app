-- Store page sections (storefront): a store owner arranges banners, promo
-- banners with a button, swipe rows and product grids for their store page.
-- Stored on the store's own row; owners already update their own row under
-- the existing businesses policies, and everyone can read businesses.
-- Shape: { "sections": [ { "id", "type": "cover"|"banner"|"row"|"grid",
--   "title", "subtitle", "image", "button", "link", "source", "limit", "items" } ] }
alter table public.businesses add column if not exists storefront jsonb;

-- Keep it small: at most 12 sections, and the whole value under 20 KB.
alter table public.businesses drop constraint if exists businesses_storefront_size;
alter table public.businesses add constraint businesses_storefront_size check (
  storefront is null or (
    jsonb_typeof(storefront) = 'object'
    and coalesce(jsonb_array_length(case when jsonb_typeof(storefront->'sections') = 'array' then storefront->'sections' else '[]'::jsonb end), 0) <= 12
    and pg_column_size(storefront) < 20000
  )
);

notify pgrst, 'reload schema';
