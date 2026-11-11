-- Main header picture on Home, set by the super admin in Admin -> Settings.
-- Empty = the illustrated island scene.
alter table public.platform_settings add column if not exists hero_image_url text;
