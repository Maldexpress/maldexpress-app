-- Store the big text / json columns with lz4 compression instead of the
-- default pglz. Postgres compresses any value over ~2 KB automatically; lz4
-- is several times faster to compress and read back, at a similar size.
-- Applies to values written from now on; existing rows are left as they are
-- (nothing is rewritten or deleted).
alter table public.items
  alter column description set compression lz4,
  alter column images set compression lz4,
  alter column photo_prints set compression lz4,
  alter column photo_hashes set compression lz4,
  alter column options set compression lz4;
alter table public.orders
  alter column slip_url set compression lz4,
  alter column slip_enc set compression lz4,
  alter column handoff_photo_url set compression lz4;
alter table public.rental_bookings
  alter column slip_url set compression lz4,
  alter column slip_enc set compression lz4;
alter table public.featured_requests alter column slip_url set compression lz4;
alter table public.pro_upgrade_requests alter column slip_url set compression lz4;
alter table public.support_messages alter column attachment set compression lz4;
alter table public.businesses alter column storefront set compression lz4;
