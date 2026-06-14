-- 0003_canonical_rebuild.sql
-- =============================================================================
-- AUTHORITATIVE SCHEMA BASELINE for the SENTRA Supabase backend.
-- This file reflects the live DB after the full canonical rebuild (applied to
-- project fsxobkynhyxkmunpzgel as tracked migrations rebuild_00..rebuild_10).
-- It SUPERSEDES the drifted 0001_unified_schema.sql, which no longer matches reality.
--
-- Conventions: lat/lng doubles (not geometry) for pings & presence; jsonb GeoJSON
-- for zone boundaries; status/severity/source/risk_level guarded by CHECK
-- constraints; one consolidated RLS policy set per table; auth.users + PostGIS
-- are NOT managed here.
-- =============================================================================

-- ── Shared trigger function ─────────────────────────────────────────────────
create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = public as $fn$
begin new.updated_at = now(); return new; end;
$fn$;

-- ── profiles ────────────────────────────────────────────────────────────────
create table public.profiles (
  id                    uuid primary key references auth.users(id) on delete cascade,
  full_name             text,
  phone                 text,
  age                   integer,
  blood_group           text,
  home_address          text,
  home_lat              double precision,
  home_lng              double precision,
  gender                text,
  registration_complete boolean not null default false,
  created_at            timestamptz default now(),
  updated_at            timestamptz default now()
);
alter table public.profiles enable row level security;
create policy profiles_read   on public.profiles for select to anon, authenticated using (true);
create policy profiles_insert on public.profiles for insert to authenticated with check ((select auth.uid()) = id);
create policy profiles_update on public.profiles for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);
create trigger trg_profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();

-- profiles are auto-created on signup by public.handle_new_user() via the
-- on_auth_user_created trigger on auth.users (defined outside this file, kept intact).

-- ── emergency_contacts ──────────────────────────────────────────────────────
create table public.emergency_contacts (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null unique references public.profiles(id) on delete cascade,
  contact_name   text not null,
  contact_number text not null,
  relationship   text,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);
alter table public.emergency_contacts enable row level security;
create policy ec_select on public.emergency_contacts for select to authenticated using ((select auth.uid()) = user_id);
create policy ec_insert on public.emergency_contacts for insert to authenticated with check ((select auth.uid()) = user_id);
create policy ec_update on public.emergency_contacts for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy ec_delete on public.emergency_contacts for delete to authenticated using ((select auth.uid()) = user_id);
create trigger trg_emergency_contacts_touch before update on public.emergency_contacts for each row execute function public.touch_updated_at();

-- ── trips + SOS->incident trigger ───────────────────────────────────────────
create or replace function public.sos_trip_to_incident()
returns trigger language plpgsql security definer set search_path = public, extensions as $fn$
declare v_lat double precision; v_lng double precision; v_name text;
begin
  if new.status = 'sos' and (old.status is distinct from 'sos') then
    select latitude, longitude into v_lat, v_lng
      from public.trip_pings where trip_id = new.id order by "timestamp" desc limit 1;
    if v_lat is null then
      if new.start_location is not null then
        v_lat := st_y(new.start_location::geometry); v_lng := st_x(new.start_location::geometry);
      else return new; end if;
    end if;
    select full_name into v_name from public.profiles where id = new.user_id;
    insert into public.incidents (user_id, status, severity, latitude, longitude, source, display_name, notes)
    values (new.user_id, 'open', 'high', v_lat, v_lng, 'device', coalesce(v_name, 'SENTRA user'), 'Auto-created from trip SOS');
  end if;
  return new;
end;
$fn$;

create table public.trips (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid references auth.users(id) on delete cascade,
  status           text not null default 'active' check (status in ('active','sos','completed','cancelled')),
  start_location   geometry,
  destination      geometry,
  expected_route   geometry,
  expected_arrival timestamptz,
  started_at       timestamptz not null default now(),
  created_at       timestamptz default now(),
  updated_at       timestamptz default now()
);
create index trips_user_status_idx on public.trips (user_id, status);
alter table public.trips enable row level security;
create policy trips_select on public.trips for select to authenticated using ((select auth.uid()) = user_id);
create policy trips_insert on public.trips for insert to authenticated with check ((select auth.uid()) = user_id);
create policy trips_update on public.trips for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy trips_delete on public.trips for delete to authenticated using ((select auth.uid()) = user_id);
create trigger trg_trips_touch before update on public.trips for each row execute function public.touch_updated_at();
create trigger trg_trip_sos_to_incident after update on public.trips for each row execute function public.sos_trip_to_incident();

-- ── live_locations (presence) ───────────────────────────────────────────────
create table public.live_locations (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  latitude       double precision not null,
  longitude      double precision not null,
  heading        double precision,
  speed          double precision,
  accuracy       double precision,
  source_type    text not null default 'online' check (source_type in ('online','offline','mesh')),
  mesh_hop_count integer not null default 0,
  updated_at     timestamptz not null default now()
);
alter table public.live_locations enable row level security;
create policy ll_select on public.live_locations for select to anon, authenticated using (true);
create policy ll_insert on public.live_locations for insert to authenticated with check ((select auth.uid()) = user_id);
create policy ll_update on public.live_locations for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy ll_delete on public.live_locations for delete to authenticated using ((select auth.uid()) = user_id);

-- ── trip_pings + ping->presence sync ────────────────────────────────────────
create or replace function public.sync_trip_ping_to_live_location()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  insert into public.live_locations (user_id, latitude, longitude, source_type, mesh_hop_count, updated_at)
  values (new.user_id, new.latitude, new.longitude, 'online', 0, now())
  on conflict (user_id) do update
    set latitude = excluded.latitude, longitude = excluded.longitude, source_type = 'online', updated_at = now();
  return new;
end;
$fn$;

create table public.trip_pings (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid references public.trips(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  latitude    double precision not null,
  longitude   double precision not null,
  "timestamp" timestamptz not null default now()
);
create index trip_pings_trip_id_idx   on public.trip_pings (trip_id);
create index trip_pings_timestamp_idx on public.trip_pings ("timestamp" desc);
create index trip_pings_user_id_idx   on public.trip_pings (user_id);
alter table public.trip_pings enable row level security;
create policy tp_select on public.trip_pings for select to authenticated using ((select auth.uid()) = user_id);
create policy tp_insert on public.trip_pings for insert to authenticated with check ((select auth.uid()) = user_id);
create trigger trg_sync_ping_to_live after insert on public.trip_pings for each row execute function public.sync_trip_ping_to_live_location();

-- ── incidents ───────────────────────────────────────────────────────────────
create table public.incidents (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references auth.users(id) on delete set null,
  status       text not null default 'open'   check (status in ('open','acknowledged','monitoring','resolved','escalated')),
  severity     text not null default 'medium' check (severity in ('low','medium','high')),
  latitude     double precision not null,
  longitude    double precision not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz,
  resolved_at  timestamptz,
  zone_id      uuid,
  notes        text,
  assigned_to  text,
  source       text check (source in ('audio','manual','device','route','synthetic')),
  display_name text
);
create index incidents_user_id_idx on public.incidents (user_id);
alter table public.incidents enable row level security;
create policy inc_select on public.incidents for select to anon, authenticated using (true);
create policy inc_insert on public.incidents for insert to authenticated with check ((select auth.uid()) = user_id);
-- Deliberately permissive: dashboard (not row owner) acknowledges/resolves. Follow-up: authority role.
create policy inc_update on public.incidents for update to anon, authenticated using (true) with check (true);

-- ── zones (dashboard-managed manual zones) ──────────────────────────────────
create table public.zones (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  risk_level      text not null default 'green' check (risk_level in ('green','yellow','red')),
  polygon_geojson jsonb not null,
  description     text,
  active_hours    text,
  incident_count  integer default 0,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);
alter table public.zones enable row level security;
-- Deliberately permissive: dashboard CRUD via anon key. Follow-up: authority role.
create policy zones_all on public.zones for all to anon, authenticated using (true) with check (true);
create trigger trg_zones_touch before update on public.zones for each row execute function public.touch_updated_at();

-- ── dynamic_zones (backend DBSCAN output) ───────────────────────────────────
create table public.dynamic_zones (
  id         uuid primary key default gen_random_uuid(),
  risk_level text not null default 'red' check (risk_level in ('green','yellow','red')),
  boundary   jsonb not null,
  source     text default 'dbscan',
  created_at timestamptz not null default now()
);
alter table public.dynamic_zones enable row level security;
create policy dz_select on public.dynamic_zones for select to anon, authenticated using (true);
-- Writes are performed by the backend using the service_role key (bypasses RLS).

-- ── heatmap_zones (research reference data) ─────────────────────────────────
create table public.heatmap_zones (
  id           uuid primary key default gen_random_uuid(),
  city         text not null,
  area_name    text not null,
  latitude     double precision not null,
  longitude    double precision not null,
  radius_m     integer not null default 800,
  risk_level   text not null,
  risk_score   integer not null,
  reason       text,
  active_hours text default 'night',
  created_at   timestamptz not null default now()
);
alter table public.heatmap_zones enable row level security;
create policy hz_select on public.heatmap_zones for select to anon, authenticated using (true);
-- Seed rows were preserved during the rebuild (backup -> restore). Re-seed via the
-- backend seed scripts if starting a brand-new project.

-- ── Realtime publication ────────────────────────────────────────────────────
alter publication supabase_realtime add table public.incidents;
alter publication supabase_realtime add table public.live_locations;
alter publication supabase_realtime add table public.zones;
alter publication supabase_realtime add table public.dynamic_zones;
alter publication supabase_realtime add table public.heatmap_zones;

-- ── Harden SECURITY DEFINER functions (triggers still fire) ─────────────────
revoke execute on function public.handle_new_user()                 from anon, authenticated, public;
revoke execute on function public.sos_trip_to_incident()            from anon, authenticated, public;
revoke execute on function public.sync_trip_ping_to_live_location() from anon, authenticated, public;
