-- Customer reviews with star ratings on the item page (About this item).
-- Anyone can read them. Only a signed-in customer who has a delivered order
-- containing the item can write one (a "verified buyer"), one per item, and
-- they can edit or delete their own. The server fills in who wrote it.
create table if not exists public.item_reviews (
  id text primary key,
  item_id text not null references public.items(id) on delete cascade,
  business_id text,
  user_id text not null default public.app_uid(),
  reviewer_name text,
  rating int not null check (rating between 1 and 5),
  comment text check (comment is null or length(comment) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (item_id, user_id)
);
create index if not exists item_reviews_item_idx on public.item_reviews (item_id, created_at desc);

create or replace function public.item_review_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') = 'service_role' then return NEW; end if;
  if TG_OP = 'INSERT' then
    NEW.user_id := public.app_uid();
    if NEW.user_id is null then raise exception 'sign_in_required'; end if;
    if not exists (select 1 from orders o
                   where o.customer_id = NEW.user_id and o.status = 'delivered'
                     and o.items @> jsonb_build_array(jsonb_build_object('itemId', NEW.item_id))) then
      raise exception 'review_needs_purchase';
    end if;
    NEW.created_at := now();
  else
    NEW.user_id := OLD.user_id; NEW.item_id := OLD.item_id; NEW.created_at := OLD.created_at;
  end if;
  NEW.business_id := (select business_id from items where id = NEW.item_id);
  NEW.updated_at := now();
  return NEW;
end; $$;
drop trigger if exists item_review_guard on public.item_reviews;
create trigger item_review_guard before insert or update on public.item_reviews
  for each row execute function public.item_review_guard();

alter table public.item_reviews enable row level security;
drop policy if exists "reviews read"   on public.item_reviews;
drop policy if exists "reviews insert" on public.item_reviews;
drop policy if exists "reviews update" on public.item_reviews;
drop policy if exists "reviews delete" on public.item_reviews;
create policy "reviews read"   on public.item_reviews for select to anon, authenticated using (true);
create policy "reviews insert" on public.item_reviews for insert to anon, authenticated with check (public.app_uid() is not null);
create policy "reviews update" on public.item_reviews for update to anon, authenticated using (user_id = public.app_uid()) with check (user_id = public.app_uid());
create policy "reviews delete" on public.item_reviews for delete to anon, authenticated using (user_id = public.app_uid() or public.is_admin());
grant select, insert, update, delete on public.item_reviews to anon, authenticated;
