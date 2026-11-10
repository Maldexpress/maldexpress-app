-- Sizes for items (fashion): comma-separated text, e.g. "S, M, L, XL".
-- Customers pick one before adding to cart; the order line names the size.
alter table public.items add column if not exists sizes text;
notify pgrst, 'reload schema';
