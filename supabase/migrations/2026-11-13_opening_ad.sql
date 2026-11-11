-- Opening ad: a full-screen image or video shown to everyone when the app
-- opens, for ad_seconds (10), skippable after ad_skip_after (5). Set in
-- Admin -> Settings; off by default.
alter table public.platform_settings add column if not exists ad_enabled    boolean not null default false;
alter table public.platform_settings add column if not exists ad_media_url  text;
alter table public.platform_settings add column if not exists ad_media_type text not null default 'image' check (ad_media_type in ('image','video'));
alter table public.platform_settings add column if not exists ad_link       text;
alter table public.platform_settings add column if not exists ad_seconds    int  not null default 10 check (ad_seconds between 3 and 30);
alter table public.platform_settings add column if not exists ad_skip_after int  not null default 5  check (ad_skip_after between 0 and 30);
