-- Pictures the Super Admin can set for the shop front (Admin -> Settings ->
-- Home pictures), next to hero_image_url (the main header / first PC slide):
--   banner_auction, banner_rental  the 2nd and 3rd PC header slides
--   promo_sell, promo_ride         the "Sell on Maarukeytu" / "Deliver on your island" cards
--   sponsored_bg                   the Sponsored panel's background
-- Each value is a public photo URL (uploaded through upload-item-photo);
-- a missing key means the built-in look. platform_settings is already
-- readable by everyone and writable only by admins, so no policy changes.
alter table public.platform_settings
  add column if not exists site_images jsonb not null default '{}'::jsonb;
comment on column public.platform_settings.site_images is
  'Admin-set shop front pictures: banner_auction, banner_rental, promo_sell, promo_ride, sponsored_bg (photo URLs).';
