-- Saved addresses remember the island (island-wise delivery), so checkout can
-- start on the customer's default island / Greater Malé zone.
alter table public.customer_addresses add column if not exists island text;
notify pgrst, 'reload schema';
