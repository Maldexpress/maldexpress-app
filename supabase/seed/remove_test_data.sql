-- Removes everything added by test_data.sql (and turns the test opening ad off).
begin;
delete from public.item_reviews where id like 'test_%';
delete from public.rider_bank_accounts where rider_id like 'test_%';
delete from public.delivery_persons where id like 'test_%';
delete from public.items where id like 'test_%';
delete from public.businesses where id like 'test_%';
update public.platform_settings set ad_enabled = false, ad_media_url = null where id = 1 and ad_media_url like '%/seed/maldexpress-test-ad.mp4';
commit;
