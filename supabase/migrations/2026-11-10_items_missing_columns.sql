-- The app has been sending three item fields the live table never had
-- (discount %, rental deposit, description), so every item save was rejected
-- ("Could not find the 'description' column of 'items'"). Add them.
alter table public.items add column if not exists description text;
alter table public.items add column if not exists discount_percent numeric not null default 0;
alter table public.items add column if not exists rental_deposit numeric not null default 0;
do $$ begin
  if not exists (select 1 from pg_constraint where conname='items_discount_percent_check') then
    alter table public.items add constraint items_discount_percent_check check (discount_percent between 0 and 90);
  end if;
  if not exists (select 1 from pg_constraint where conname='items_rental_deposit_check') then
    alter table public.items add constraint items_rental_deposit_check check (rental_deposit >= 0);
  end if;
end $$;
-- PostgREST caches the table shape; reload it so the new columns are usable at once.
notify pgrst, 'reload schema';
