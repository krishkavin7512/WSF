-- =============================================================================
-- SENTRA / WSF — UNIFIED SCHEMA
-- Migration: 0001_unified_schema
-- =============================================================================
-- Who touches what:
--   mobile    : auth (OTP) → profiles; trips (insert/update/select);
--               trip_pings (insert); rpc get_active_zones()
--   backend   : dynamic_zones (read /zones & safenav, written by zone_generator.py)
--               incidents (read lat/lng for DBSCAN) — uses SERVICE ROLE, bypasses RLS
--   dashboard : zones, live_locations, incidents, responders, heatmap_zones, dynamic_zones
--               — anon client, no login required (demo-grade, see RLS section)
--
-- Bridges:
--   1. trip_pings INSERT → upsert live_locations  (mobile movement → dashboard map)
--   2. trips.status = 'sos' → insert incidents row (SOS alert → dashboard feed)
--
-- This script is idempotent — safe to run more than once.
-- =============================================================================

set search_path = public, extensions;

create extension if not exists postgis;
create extension if not exists pgcrypto;

-- =============================================================================
-- 1. PROFILES
-- =============================================================================
create table if not exists public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  full_name  text,
  phone      text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

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

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =============================================================================
-- 2. TRIPS
-- =============================================================================
create table if not exists public.trips (
  id               uuid        primary key default gen_random_uuid(),
  user_id          uuid        references auth.users (id) on delete cascade,
  status           text        not null default 'active', -- active|completed|sos|cancelled
  start_location   geometry(Point, 4326),
  destination      geometry(Point, 4326),
  expected_route   geometry(LineString, 4326),
  expected_arrival timestamptz,
  created_at       timestamptz default now(),
  updated_at       timestamptz default now()
);

create index if not exists trips_user_status_idx on public.trips (user_id, status);

-- =============================================================================
-- 3. TRIP_PINGS
-- =============================================================================
create table if not exists public.trip_pings (
  id               uuid        primary key default gen_random_uuid(),
  trip_id          uuid        references public.trips (id) on delete cascade,
  current_location geometry(Point, 4326),
  created_at       timestamptz default now()
);

create index if not exists trip_pings_trip_idx
  on public.trip_pings (trip_id, created_at desc);

-- =============================================================================
-- 4. DYNAMIC_ZONES  (written by zone_generator.py via DBSCAN)
--
-- boundary is jsonb — stores a GeoJSON Polygon or MultiPolygon object:
--   { "type": "Polygon", "coordinates": [[[ lng, lat ], ...]] }
--
-- The Python client (supabase-py) inserts the shapely `mapping()` dict directly.
-- The JS client (MapView.tsx) reads it back as a JS object or string and parses
-- accordingly. PostGIS geometry is NOT used here so the REST API can round-trip
-- the GeoJSON without a cast.
-- =============================================================================
create table if not exists public.dynamic_zones (
  id         uuid        primary key default gen_random_uuid(),
  risk_level text        not null default 'red', -- red | yellow
  source     text        default 'dbscan',
  boundary   jsonb,                              -- GeoJSON Polygon / MultiPolygon
  created_at timestamptz default now()
);

create index if not exists dynamic_zones_risk_idx on public.dynamic_zones (risk_level);

-- =============================================================================
-- 5. HEATMAP_ZONES  (manually curated static danger areas per city)
-- =============================================================================
create table if not exists public.heatmap_zones (
  id         uuid             primary key default gen_random_uuid(),
  area_name  text             not null,
  city       text             not null,
  latitude   double precision not null,
  longitude  double precision not null,
  radius_m   integer          not null default 300,
  risk_level text             not null default 'medium', -- high | medium | low
  reason     text,
  created_at timestamptz      default now()
);

create index if not exists heatmap_zones_city_idx on public.heatmap_zones (city);

-- =============================================================================
-- 6. ZONES  (manually managed zones — dashboard CRUD)
-- =============================================================================
create table if not exists public.zones (
  id              uuid        primary key default gen_random_uuid(),
  name            text        not null,
  risk_level      text        not null default 'green', -- green | yellow | red
  polygon_geojson jsonb       not null,
  description     text,
  active_hours    text,
  incident_count  integer     default 0,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

create index if not exists zones_risk_idx on public.zones (risk_level);

-- =============================================================================
-- 7. INCIDENTS
--
-- severity is an integer matching the CSV pipeline:
--   1 = low, 2 = medium, 3 = high
--
-- location (PostGIS point) is auto-derived from latitude/longitude so that
-- the DBSCAN zone generator's ST_* queries work without a separate insert step.
-- =============================================================================
create table if not exists public.incidents (
  id           uuid             primary key default gen_random_uuid(),
  user_id      text,
  status       text             not null default 'open',
    -- open | acknowledged | monitoring | resolved | escalated
  severity     integer          not null default 2,  -- 1=low 2=medium 3=high
  latitude     double precision not null,
  longitude    double precision not null,
  location     geometry(Point, 4326)
                 generated always as (
                   st_setsrid(st_makepoint(longitude, latitude), 4326)
                 ) stored,
  zone_id      uuid,
  notes        text,
  assigned_to  text,
  source       text,            -- audio | manual | device | route | synthetic
  display_name text,
  created_at   timestamptz      default now(),
  updated_at   timestamptz,
  resolved_at  timestamptz
);

create index if not exists incidents_status_idx  on public.incidents (status);
create index if not exists incidents_created_idx on public.incidents (created_at desc);
create index if not exists incidents_gix         on public.incidents using gist (location);

-- =============================================================================
-- 8. LIVE_LOCATIONS  (latest position per user — dashboard realtime map)
--    Written by LocationService._writeBeacon on every GPS fix.
--    user_id is uuid (matches auth.users.id) so RLS auth.uid() comparisons
--    work without casting.
-- =============================================================================
create table if not exists public.live_locations (
  user_id        uuid             primary key references auth.users (id) on delete cascade,
  latitude       double precision not null,
  longitude      double precision not null,
  heading        double precision,
  speed          double precision,
  accuracy       double precision, -- horizontal error radius in metres (optional)
  source_type    text             not null default 'online', -- online | mesh
  mesh_hop_count integer          not null default 0,
  updated_at     timestamptz      not null default now()
);

-- Backfill existing tables that pre-date this migration
alter table public.live_locations
  add column if not exists accuracy double precision;

create index if not exists live_locations_updated_idx
  on public.live_locations (updated_at desc);

-- =============================================================================
-- 9. RESPONDERS
-- =============================================================================
create table if not exists public.responders (
  id             uuid        primary key default gen_random_uuid(),
  name           text        not null,
  type           text,       -- police | volunteer | medical
  status         text        default 'offline', -- active | responding | offline
  latitude       double precision,
  longitude      double precision,
  assigned_zone  text,
  phone          text,
  badge_number   text,
  vehicle_number text,
  current_task   text,
  last_active    timestamptz default now(),
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);

-- =============================================================================
-- 10. RPC: get_active_zones()
--     Called by the Flutter mobile app to load geofence polygons.
--     Unions DBSCAN dynamic zones with manually managed zones.
--     SECURITY DEFINER so it executes as the function owner, bypassing RLS.
--
--     boundary column in dynamic_zones is jsonb — return it directly.
--     zones.polygon_geojson may wrap the geometry in a GeoJSON Feature object;
--     we unwrap it to return the bare geometry object in both cases.
-- =============================================================================
create or replace function public.get_active_zones()
returns table (id uuid, risk_level text, boundary jsonb, source text)
language sql
stable
security definer
set search_path = public, extensions
as $$
  -- DBSCAN zones: boundary is already a bare GeoJSON geometry object
  select
    dz.id,
    dz.risk_level,
    dz.boundary,
    coalesce(dz.source, 'dbscan') as source
  from public.dynamic_zones dz
  where dz.boundary is not null

  union all

  -- Manual zones: polygon_geojson may be a GeoJSON Feature wrapper
  select
    z.id,
    z.risk_level,
    case
      when z.polygon_geojson ? 'geometry' then z.polygon_geojson -> 'geometry'
      else z.polygon_geojson
    end as boundary,
    'manual' as source
  from public.zones z
  where z.polygon_geojson is not null;
$$;

grant execute on function public.get_active_zones() to anon, authenticated;

-- =============================================================================
-- 11. BRIDGE: trip_pings → live_locations
--     Every location ping from the mobile app upserts the user's current
--     position into live_locations so the dashboard map updates in real time.
-- =============================================================================
create or replace function public.sync_trip_ping_to_live_location()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user uuid;
begin
  select user_id into v_user from public.trips where id = new.trip_id;
  if v_user is null or new.current_location is null then
    return new;
  end if;

  insert into public.live_locations (
    user_id, latitude, longitude, source_type, mesh_hop_count, updated_at
  )
  values (
    v_user,                     -- uuid column — no cast needed
    st_y(new.current_location),
    st_x(new.current_location),
    'online',
    0,
    now()
  )
  on conflict (user_id) do update set
    latitude       = excluded.latitude,
    longitude      = excluded.longitude,
    source_type    = 'online',
    updated_at     = now();

  return new;
end;
$$;

drop trigger if exists trg_trip_ping_to_live on public.trip_pings;
create trigger trg_trip_ping_to_live
  after insert on public.trip_pings
  for each row execute function public.sync_trip_ping_to_live_location();

-- =============================================================================
-- 12. BRIDGE: trips.status = 'sos' → incidents
--     When a user triggers SOS, auto-create an incident at their last known
--     position so it appears immediately in the dashboard feed.
-- =============================================================================
create or replace function public.sos_trip_to_incident()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_geom geometry;
  v_name text;
begin
  if new.status = 'sos' and (old.status is distinct from 'sos') then
    select current_location into v_geom
    from public.trip_pings
    where trip_id = new.id
    order by created_at desc
    limit 1;

    if v_geom is null then v_geom := new.start_location; end if;
    if v_geom is null then return new; end if;

    select full_name into v_name from public.profiles where id = new.user_id;

    insert into public.incidents (
      user_id, status, severity, latitude, longitude,
      source, display_name, notes
    )
    values (
      new.user_id::text,
      'open',
      3,
      st_y(v_geom),
      st_x(v_geom),
      'device',
      coalesce(v_name, 'SENTRA user'),
      'Auto-created from trip SOS'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_trip_sos_to_incident on public.trips;
create trigger trg_trip_sos_to_incident
  after update on public.trips
  for each row execute function public.sos_trip_to_incident();

-- =============================================================================
-- 13. GENERIC updated_at MAINTENANCE
-- =============================================================================
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_zones_touch on public.zones;
create trigger trg_zones_touch
  before update on public.zones
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_trips_touch on public.trips;
create trigger trg_trips_touch
  before update on public.trips
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_responders_touch on public.responders;
create trigger trg_responders_touch
  before update on public.responders
  for each row execute function public.touch_updated_at();

-- =============================================================================
-- 14. REALTIME — subscribe dashboard tables
-- =============================================================================
do $$
declare
  t text;
begin
  foreach t in array array[
    'incidents',
    'live_locations',
    'zones',
    'dynamic_zones',
    'heatmap_zones'
  ] loop
    begin
      execute format(
        'alter publication supabase_realtime add table public.%I', t
      );
    exception when duplicate_object then
      null; -- already subscribed
    end;
  end loop;
end $$;

-- =============================================================================
-- 15. ROW LEVEL SECURITY
-- =============================================================================
alter table public.profiles       enable row level security;
alter table public.trips          enable row level security;
alter table public.trip_pings     enable row level security;
alter table public.dynamic_zones  enable row level security;
alter table public.heatmap_zones  enable row level security;
alter table public.zones          enable row level security;
alter table public.incidents      enable row level security;
alter table public.live_locations enable row level security;
alter table public.responders     enable row level security;

-- ── Mobile: authenticated, scoped to the owning user ─────────────────────────

drop policy if exists profiles_self_rw on public.profiles;
create policy profiles_self_rw on public.profiles
  for all to authenticated
  using     (auth.uid() = id)
  with check (auth.uid() = id);

drop policy if exists trips_owner_rw on public.trips;
create policy trips_owner_rw on public.trips
  for all to authenticated
  using     (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists trip_pings_owner_ins on public.trip_pings;
create policy trip_pings_owner_ins on public.trip_pings
  for insert to authenticated
  with check (
    exists (
      select 1 from public.trips t
      where t.id = trip_id and t.user_id = auth.uid()
    )
  );

drop policy if exists trip_pings_owner_sel on public.trip_pings;
create policy trip_pings_owner_sel on public.trip_pings
  for select to authenticated
  using (
    exists (
      select 1 from public.trips t
      where t.id = trip_id and t.user_id = auth.uid()
    )
  );

-- ── Dashboard: anon + authenticated read/write (demo-grade) ──────────────────
-- Replace with authority-scoped policies before production deployment.

drop policy if exists zones_anon_all on public.zones;
create policy zones_anon_all on public.zones
  for all to anon, authenticated using (true) with check (true);

drop policy if exists incidents_anon_read on public.incidents;
create policy incidents_anon_read on public.incidents
  for select to anon, authenticated using (true);

drop policy if exists incidents_anon_write on public.incidents;
create policy incidents_anon_write on public.incidents
  for update to anon, authenticated using (true) with check (true);

drop policy if exists incidents_anon_insert on public.incidents;
create policy incidents_anon_insert on public.incidents
  for insert to anon, authenticated with check (true);

drop policy if exists live_locations_anon_read on public.live_locations;
create policy live_locations_anon_read on public.live_locations
  for select to anon, authenticated using (true);

drop policy if exists dynamic_zones_read on public.dynamic_zones;
create policy dynamic_zones_read on public.dynamic_zones
  for select to anon, authenticated using (true);

drop policy if exists heatmap_zones_read on public.heatmap_zones;
create policy heatmap_zones_read on public.heatmap_zones
  for select to anon, authenticated using (true);

drop policy if exists responders_anon_read on public.responders;
create policy responders_anon_read on public.responders
  for select to anon, authenticated using (true);

-- Mobile app (LocationService._writeBeacon) upserts its own beacon on every
-- GPS fix. user_id is uuid so auth.uid() = user_id compares uuid = uuid.
drop policy if exists live_locations_own_upsert on public.live_locations;
create policy live_locations_own_upsert on public.live_locations
  for all to authenticated
  using     (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- dynamic_zones writes come from the backend SERVICE ROLE key (bypasses RLS).
-- live_locations is also written by the SECURITY DEFINER bridge trigger.

-- =============================================================================
-- HARDENING NOTES (apply before production)
-- =============================================================================
-- 1. Add an auth gate to the Next.js dashboard (wire useSupabaseAuth).
-- 2. Drop the *_anon_* policies above; replace with role-scoped ones, e.g.:
--      create or replace function public.is_authority() returns boolean
--        language sql stable as
--        $$ select coalesce((auth.jwt() ->> 'role') = 'authority', false) $$;
--      create policy incidents_authority_rw on public.incidents
--        for all to authenticated using (is_authority()) with check (is_authority());
-- 3. Restrict heatmap_zones and zones writes to authority role.
-- 4. Enable email confirmations in [auth.email] once SMTP is configured.
