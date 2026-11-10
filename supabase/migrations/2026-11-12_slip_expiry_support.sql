-- Bank slips leave the database once the store confirms the payment, and a
-- Live support desk (tickets) where a store can ask for an old slip.
--
-- 1. When a store confirms a slip (order -> paid / settled, rental booking
--    charge -> collected), slip_confirmed_at is stamped.
-- 2. Every 15 minutes pg_cron calls the purge-slips edge function, which moves
--    each confirmed slip into the private `slip-archive`
--    bucket (exactly as stored: still encrypted for the customer and the store
--    when it was encrypted) and clears it from the row.
-- 3. Support tickets: anyone signed in opens a ticket from the menu; the super
--    admin answers from Admin -> Live support. For a slip request the admin
--    presses "Send the slip" (support-send-slip function), which attaches the
--    archived slip to the ticket; the store's app opens it with its own key.

-- ---------- 1. Slip confirmation time ----------
alter table public.orders          add column if not exists slip_confirmed_at timestamptz;
alter table public.orders          add column if not exists slip_archived_at  timestamptz;
alter table public.orders          add column if not exists slip_archive_path text;
alter table public.rental_bookings add column if not exists slip_confirmed_at timestamptz;
alter table public.rental_bookings add column if not exists slip_archived_at  timestamptz;
alter table public.rental_bookings add column if not exists slip_archive_path text;

create or replace function public.orders_slip_confirmed() returns trigger
language plpgsql set search_path = public as $$
begin
  -- A removed slip stays removed: an app that loaded the row earlier can't
  -- write the old slip back when it saves something else on the order.
  if TG_OP = 'UPDATE' and OLD.slip_archived_at is not null then
    NEW.slip_url := null; NEW.slip_enc := null; NEW.slip_iv := null; NEW.slip_keys := null;
    NEW.slip_archived_at := OLD.slip_archived_at; NEW.slip_archive_path := OLD.slip_archive_path;
    return NEW;
  end if;
  if NEW.slip_confirmed_at is null
     and NEW.payment_status in ('paid','settled')
     and (NEW.slip_url is not null or NEW.slip_enc is not null) then
    NEW.slip_confirmed_at := now();
  end if;
  return NEW;
end; $$;
drop trigger if exists orders_slip_confirmed on public.orders;
create trigger orders_slip_confirmed before insert or update on public.orders
  for each row execute function public.orders_slip_confirmed();

create or replace function public.bookings_slip_confirmed() returns trigger
language plpgsql set search_path = public as $$
begin
  -- A removed slip stays removed: an app that loaded the row earlier can't
  -- write the old slip back when it saves something else on the order.
  if TG_OP = 'UPDATE' and OLD.slip_archived_at is not null then
    NEW.slip_url := null; NEW.slip_enc := null; NEW.slip_iv := null; NEW.slip_keys := null;
    NEW.slip_archived_at := OLD.slip_archived_at; NEW.slip_archive_path := OLD.slip_archive_path;
    return NEW;
  end if;
  if NEW.slip_confirmed_at is null
     and NEW.charge_status = 'collected'
     and (NEW.slip_url is not null or NEW.slip_enc is not null) then
    NEW.slip_confirmed_at := now();
  end if;
  return NEW;
end; $$;
drop trigger if exists bookings_slip_confirmed on public.rental_bookings;
create trigger bookings_slip_confirmed before insert or update on public.rental_bookings
  for each row execute function public.bookings_slip_confirmed();

-- Slips that were already confirmed before this change are removed at the first run.
update public.orders set slip_confirmed_at = now()
 where slip_confirmed_at is null and payment_status in ('paid','settled') and (slip_url is not null or slip_enc is not null);
update public.rental_bookings set slip_confirmed_at = now()
 where slip_confirmed_at is null and charge_status = 'collected' and (slip_url is not null or slip_enc is not null);

-- ---------- 2. Private archive bucket ----------
insert into storage.buckets (id, name, public) values ('slip-archive', 'slip-archive', false)
on conflict (id) do update set public = false;
-- No storage policies: only edge functions (service role) can read or write it.

-- ---------- 3. Support tickets ----------
create table if not exists public.support_tickets (
  id text primary key,
  user_id text not null default public.app_uid(),
  user_email text,
  role text not null default 'customer' check (role in ('customer','business','delivery')),
  business_id text references public.businesses(id) on delete set null,
  order_id text,
  booking_id text,
  topic text not null default 'other' check (topic in ('slip','order','payment','delivery','account','other')),
  subject text not null check (length(subject) between 1 and 120),
  status text not null default 'open' check (status in ('open','answered','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists support_tickets_user_idx   on public.support_tickets (user_id, updated_at desc);
create index if not exists support_tickets_status_idx on public.support_tickets (status, updated_at desc);

create table if not exists public.support_messages (
  id text primary key,
  ticket_id text not null references public.support_tickets(id) on delete cascade,
  sender_id text not null default public.app_uid(),
  from_admin boolean not null default false,
  body text not null default '' check (length(body) <= 4000),
  attachment jsonb,            -- an archived slip sent by support: {kind, ref, slip_url | slip_enc, slip_iv, slip_keys}
  created_at timestamptz not null default now()
);
create index if not exists support_messages_ticket_idx on public.support_messages (ticket_id, created_at);

-- Who sent it is decided by the server, not the app.
create or replace function public.support_ticket_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    NEW.user_id := public.app_uid(); NEW.status := 'open'; NEW.created_at := now(); NEW.updated_at := now();
    if NEW.user_id is null then raise exception 'sign_in_required'; end if;
    if NEW.business_id is not null and not exists (select 1 from businesses b where b.id = NEW.business_id and b.owner_id = NEW.user_id) then
      NEW.business_id := null;
    end if;
  else
    NEW.user_id := OLD.user_id; NEW.created_at := OLD.created_at; NEW.business_id := OLD.business_id;
    NEW.order_id := OLD.order_id; NEW.booking_id := OLD.booking_id; NEW.topic := OLD.topic; NEW.role := OLD.role;
    if not (public.is_admin() or coalesce(auth.role(),'') = 'service_role') and NEW.status not in ('open','closed') then NEW.status := OLD.status; end if;
    NEW.updated_at := now();
  end if;
  return NEW;
end; $$;
drop trigger if exists support_ticket_guard on public.support_tickets;
create trigger support_ticket_guard before insert or update on public.support_tickets
  for each row execute function public.support_ticket_guard();

create or replace function public.support_message_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  NEW.created_at := now();
  if coalesce(auth.role(), '') <> 'service_role' then        -- from the app: the server decides who sent it
    NEW.sender_id := public.app_uid();
    if NEW.sender_id is null then raise exception 'sign_in_required'; end if;
    NEW.from_admin := public.is_admin() and not exists (select 1 from support_tickets t where t.id = NEW.ticket_id and t.user_id = NEW.sender_id);
    NEW.attachment := null;                                   -- slips are attached only by the support-send-slip function
  end if;
  update support_tickets set status = case when NEW.from_admin then 'answered' else 'open' end, updated_at = now() where id = NEW.ticket_id;
  return NEW;
end; $$;
drop trigger if exists support_message_guard on public.support_messages;
create trigger support_message_guard before insert on public.support_messages
  for each row execute function public.support_message_guard();

alter table public.support_tickets  enable row level security;
alter table public.support_messages enable row level security;

drop policy if exists "support tickets read"   on public.support_tickets;
drop policy if exists "support tickets insert" on public.support_tickets;
drop policy if exists "support tickets update" on public.support_tickets;
create policy "support tickets read"   on public.support_tickets for select to anon, authenticated
  using (user_id = public.app_uid() or public.is_admin());
create policy "support tickets insert" on public.support_tickets for insert to anon, authenticated
  with check (public.app_uid() is not null);
create policy "support tickets update" on public.support_tickets for update to anon, authenticated
  using (user_id = public.app_uid() or public.is_admin());

drop policy if exists "support messages read"   on public.support_messages;
drop policy if exists "support messages insert" on public.support_messages;
create policy "support messages read" on public.support_messages for select to anon, authenticated
  using (exists (select 1 from public.support_tickets t where t.id = ticket_id and (t.user_id = public.app_uid() or public.is_admin())));
create policy "support messages insert" on public.support_messages for insert to anon, authenticated
  with check (exists (select 1 from public.support_tickets t where t.id = ticket_id and t.status <> 'closed' and (t.user_id = public.app_uid() or public.is_admin())));

grant select, insert, update on public.support_tickets  to anon, authenticated;
grant select, insert         on public.support_messages to anon, authenticated;

-- ---------- 4. Run the purge every 15 minutes ----------
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.unschedule(jobid) from cron.job where jobname = 'purge-confirmed-slips';
select cron.schedule('purge-confirmed-slips', '*/15 * * * *', $cron$
  select net.http_post(
    url := 'https://jbzyphtrcgrfnleocusp.supabase.co/functions/v1/purge-slips',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
$cron$);
