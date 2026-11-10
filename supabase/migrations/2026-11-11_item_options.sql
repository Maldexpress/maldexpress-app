-- Item options (attributes) for every category, e.g. {"Size":["S","M"],"Colour":["Red"]}.
-- Customers pick one value of each before adding to cart; order lines name them.
alter table public.items add column if not exists options jsonb;
notify pgrst, 'reload schema';
