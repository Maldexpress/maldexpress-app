-- Firebase third-party auth: tokens carry no Supabase `role` claim, so every
-- request runs as `anon` and the user is identified with public.app_uid().
-- These four policies were still limited to the `authenticated` role, so
-- they never matched: product photo uploads/updates/deletes were refused, and
-- marking an auction ended/settled from the app failed. Open them to anon as
-- well; app_uid() (verified Firebase user) is what actually gates them.

alter policy "owner upload product images" on storage.objects to anon, authenticated
  with check (bucket_id = 'product-images' and (storage.foldername(name))[1] = public.app_uid());
alter policy "owner update product images" on storage.objects to anon, authenticated
  using (bucket_id = 'product-images' and (storage.foldername(name))[1] = public.app_uid());
alter policy "owner delete product images" on storage.objects to anon, authenticated
  using (bucket_id = 'product-images' and (storage.foldername(name))[1] = public.app_uid());

-- Same rule as before (active/ended auctions only), plus a signed-in check now
-- that anon is allowed. Bids still go through place_bid(); column guards on
-- auction_listings are unchanged.
alter policy "signed-in update auction" on public.auction_listings to anon, authenticated
  using (status = any (array['active','ended']) and public.app_uid() is not null)
  with check (public.app_uid() is not null);
