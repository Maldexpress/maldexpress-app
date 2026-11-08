-- =========================================================================
-- EMAIL CODE VERIFICATION (2026-11-08). Firebase only verifies emails with
-- a link, and its email body can't be edited, so Maldexpress sends its own
-- 6-digit code (edge functions send-email-code / verify-email-code, email
-- delivered through Brevo). A verified code adds the Firebase uid to
-- verified_emails; app_uid() accepts either Firebase's own email_verified
-- flag or a row here. Both tables have RLS on and no policies: only the
-- edge functions (service role) touch them.
-- =========================================================================
create table if not exists public.email_codes (
  uid text primary key,
  email text not null,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts int not null default 0,
  last_sent_at timestamptz not null default now(),
  sends_in_window int not null default 1,
  window_started_at timestamptz not null default now()
);
alter table public.email_codes enable row level security;

create table if not exists public.verified_emails (
  uid text primary key,
  email text not null,
  verified_at timestamptz not null default now()
);
alter table public.verified_emails enable row level security;

create or replace function public.app_uid()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when auth.jwt()->>'iss' = 'https://securetoken.google.com/maldexpress'
     and auth.jwt()->>'aud' = 'maldexpress'
     and nullif(auth.jwt()->>'sub', '') is not null
     and (
       coalesce((auth.jwt()->>'email_verified')::boolean, false)
       or exists (select 1 from verified_emails v where v.uid = auth.jwt()->>'sub')
     )
    then auth.jwt()->>'sub'
  end;
$$;
grant execute on function public.app_uid() to anon, authenticated;

-- Lets the app ask "is this signed-in account verified yet?"
create or replace function public.my_email_verified()
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select public.app_uid() is not null; $$;
grant execute on function public.my_email_verified() to anon, authenticated;
