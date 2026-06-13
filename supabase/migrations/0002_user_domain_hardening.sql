-- =============================================================================
-- SENTRA / WSF — USER DOMAIN HARDENING
-- Migration: 0002_user_domain_hardening
-- =============================================================================
-- Scope: profiles + emergency_contacts ONLY (the user / onboarding core).
--
-- Why this exists:
--   0001_unified_schema.sql has drifted from the live database. The live
--   `profiles` table gained 7 onboarding columns, `emergency_contacts` was
--   added entirely, and several other tables diverged (incidents.severity is
--   text not integer, trip_pings reshaped, dynamic_zones lost `source`, ...).
--   None of it went through the migration system, so there was no source of
--   truth. This migration reconciles the USER DOMAIN with reality and applies
--   the agreed onboarding decisions. A full `supabase db pull` reconciliation
--   of the remaining tables is the recommended follow-up.
--
-- Decisions captured here:
--   * registration_complete is the official "onboarding done" flag.
--   * Exactly one emergency contact per user (UNIQUE(user_id), upsert/replace).
--
-- Idempotent — safe to run more than once.
-- =============================================================================

set search_path = public, extensions;

-- -----------------------------------------------------------------------------
-- 1. PROFILES — declare onboarding columns (they already exist live; this makes
--    the migration file an accurate source of truth for the user domain).
-- -----------------------------------------------------------------------------
alter table public.profiles add column if not exists age                   integer;
alter table public.profiles add column if not exists blood_group           text;
alter table public.profiles add column if not exists gender                text;
alter table public.profiles add column if not exists home_address          text;
alter table public.profiles add column if not exists home_lat              double precision;
alter table public.profiles add column if not exists home_lng              double precision;
alter table public.profiles add column if not exists registration_complete boolean not null default false;

-- 1a. Backfill the flag for users who already completed onboarding under the
--     old (age IS NOT NULL + has-contact) logic, so they are not sent back
--     through the flow on next launch.
update public.profiles p
set registration_complete = true
where p.registration_complete = false
  and p.age is not null
  and exists (
    select 1 from public.emergency_contacts ec where ec.user_id = p.id
  );

-- 1b. Auto-maintain updated_at on profile edits (touch_updated_at() from 0001).
drop trigger if exists trg_profiles_touch on public.profiles;
create trigger trg_profiles_touch
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 2. handle_new_user — align the live trigger to the better definition:
--    capture full_name from signup metadata and pin search_path (security).
-- -----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (
    new.id,
    new.raw_user_meta_data ->> 'full_name',
    new.phone
  )
  on conflict (id) do update set
    full_name  = coalesce(excluded.full_name, public.profiles.full_name),
    phone      = coalesce(excluded.phone,     public.profiles.phone),
    updated_at = now();
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. EMERGENCY_CONTACTS — one contact per user (chosen model). UNIQUE(user_id)
--    lets the app upsert(onConflict: user_id) to replace the existing contact.
-- -----------------------------------------------------------------------------
alter table public.emergency_contacts
  add column if not exists updated_at timestamptz default now();

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'emergency_contacts_user_id_key'
  ) then
    alter table public.emergency_contacts
      add constraint emergency_contacts_user_id_key unique (user_id);
  end if;
end $$;

drop trigger if exists trg_emergency_contacts_touch on public.emergency_contacts;
create trigger trg_emergency_contacts_touch
  before update on public.emergency_contacts
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 4. RLS CLEANUP — collapse the three overlapping profiles policies into two:
--    self read/write (authenticated) + dashboard read (anon, demo-grade).
--
--    NOTE (privacy): profiles_dashboard_read exposes name/phone/age/blood_group/
--    home_address to anyone with the anon key. This preserves the EXISTING
--    posture (the dashboard has no auth yet). Lock this to an authority role
--    before production — see 0001 HARDENING NOTES.
-- -----------------------------------------------------------------------------
drop policy if exists "Users can view and edit own profile" on public.profiles;
drop policy if exists "Dashboard can read all profiles"     on public.profiles;
drop policy if exists profiles_self_rw                      on public.profiles;
drop policy if exists profiles_dashboard_read               on public.profiles;

create policy profiles_self_rw on public.profiles
  for all to authenticated
  using     (auth.uid() = id)
  with check (auth.uid() = id);

create policy profiles_dashboard_read on public.profiles
  for select to anon, authenticated
  using (true);

-- emergency_contacts RLS ("Users manage own emergency contacts",
-- auth.uid() = user_id, ALL) is already correct — left unchanged.
