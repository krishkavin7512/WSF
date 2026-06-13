-- =====================================================================
-- SENTRA / WSF — UNIFIED SUPABASE SCHEMA  (paste into Supabase SQL editor)
-- =====================================================================
-- Reconciles the two code generations so the FastAPI backend, the Flutter
-- mobile app, and the Next.js dashboard all run against ONE database with a
-- live data path. No application code changes are required.
--
-- This script is idempotent — safe to run more than once.
--
-- WHO TOUCHES WHAT (verified against the code):
--   mobile  : auth(OTP) -> profiles ; trips (insert/update status, select id) ;
--             trip_pings (insert) ; rpc get_active_zones()
--   backend : dynamic_zones (read in /zones & safenav ; written by zone_generator) ;
--             incidents.location (read by DBSCAN)   [uses SERVICE ROLE -> bypasses RLS]
--   dashboard: zones, live_locations, incidents, responders  [anon client, no login]
--
-- BRIDGES added per your choice ("superset + live bridges"):
--   1. trip_pings INSERT      -> upsert live_locations   (mobile moves show on dash)
--   2. trips.status='sos'     -> insert incidents row     (SOS shows in dash feed)
--
-- SECURITY NOTE: the dashboard has no auth gate today, so it talks to Supabase
-- as the anon role. The dashboard-facing tables below use PERMISSIVE anon
-- policies so the dashboard "just runs". This is DEMO-GRADE. To harden: add an
-- auth gate to the dashboard (wire useSupabaseAuth) then replace the anon
-- policies with authenticated / authority-scoped ones (see HARDENING block).
-- =====================================================================

set search_path = public, extensions;

create extension if not exists postgis;       -- geometry types + ST_* functions
create extension if not exists pgcrypto;      -- gen_random_uuid()

-- =====================================================================
-- 1. PROFILES  (+ auto-mirror trigger on auth signup)  — mobile
-- =====================================================================
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  phone       text,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- On every new auth user, copy full_name (passed via signInWithOtp data:{}) + phone.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (new.id, new.raw_user_meta_data ->> 'full_name', new.phone)
  on conflict (id) do update
    set full_name = coalesce(excluded.full_name, public.profiles.full_name),
        phone     = coalesce(excluded.phone, public.profiles.phone),
        updated_at = now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =====================================================================
-- 2. TRIPS  — mobile escort sessions
-- =====================================================================
create table if not exists public.trips (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid references auth.users(id) on delete cascade,
  status           text not null default 'active',  -- active | completed | sos | cancelled
  start_location   geometry(Point, 4326),
  destination      geometry(Point, 4326),
  expected_route   geometry(LineString, 4326),
  expected_arrival timestamptz,
  created_at       timestamptz default now(),
  updated_at       timestamptz default now()
);
create index if not exists trips_user_status_idx on public.trips(user_id, status);

-- =====================================================================
-- 3. TRIP_PINGS  — high-frequency location pings from the mobile app
-- =====================================================================
create table if not exists public.trip_pings (
  id               uuid primary key default gen_random_uuid(),
  trip_id          uuid references public.trips(id) on delete cascade,
  current_location geometry(Point, 4326),
  created_at       timestamptz default now()
);
create index if not exists trip_pings_trip_idx on public.trip_pings(trip_id, created_at desc);

-- =====================================================================
-- 4. DYNAMIC_ZONES  — machine-generated (DBSCAN) risk polygons  — backend
-- =====================================================================
create table if not exists public.dynamic_zones (
  id         uuid primary key default gen_random_uuid(),
  risk_level text not null default 'red',     -- red | yellow
  source     text default 'dbscan',
  boundary   geometry(Geometry, 4326),        -- Polygon OR MultiPolygon (EWKT insert ok)
  created_at timestamptz default now()
);
create index if not exists dynamic_zones_gix on public.dynamic_zones using gist (boundary);

-- =====================================================================
-- 5. ZONES  — manually managed zones (dashboard CRUD)
-- =====================================================================
create table if not exists public.zones (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  risk_level      text not null default 'green',  -- green | yellow | red
  polygon_geojson jsonb not null,                 -- GeoJSON Feature {geometry:{...}}
  description     text,
  active_hours    text,
  incident_count  integer default 0,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);
create index if not exists zones_risk_idx on public.zones(risk_level);

-- =====================================================================
-- 6. INCIDENTS  — SOS / audio / manual.  Serves BOTH:
--    dashboard reads latitude/longitude floats; backend DBSCAN reads `location`.
-- =====================================================================
create table if not exists public.incidents (
  id           uuid primary key default gen_random_uuid(),
  user_id      text,
  status       text not null default 'open',     -- open|acknowledged|monitoring|resolved|escalated
  severity     text not null default 'medium',   -- low|medium|high
  latitude     double precision not null,
  longitude    double precision not null,
  -- Auto-derived PostGIS point so zone_generator.py's select("location") works:
  location     geometry(Point, 4326)
                 generated always as (st_setsrid(st_makepoint(longitude, latitude), 4326)) stored,
  zone_id      uuid,
  notes        text,
  assigned_to  text,
  source       text,                              -- audio|manual|device|route
  display_name text,
  created_at   timestamptz default now(),
  updated_at   timestamptz,
  resolved_at  timestamptz
);
create index if not exists incidents_status_idx  on public.incidents(status);
create index if not exists incidents_created_idx on public.incidents(created_at desc);
create index if not exists incidents_gix         on public.incidents using gist (location);

-- =====================================================================
-- 7. LIVE_LOCATIONS  — latest position per user (dashboard realtime map)
--    Written by the bridge trigger (below), read by the dashboard.
-- =====================================================================
create table if not exists public.live_locations (
  user_id        text primary key,
  latitude       double precision not null,
  longitude      double precision not null,
  heading        double precision,
  speed          double precision,
  accuracy       double precision,
  source_type    text default 'online',           -- online | mesh
  mesh_hop_count integer default 0,
  updated_at     timestamptz default now()
);
create index if not exists live_locations_updated_idx on public.live_locations(updated_at desc);

-- =====================================================================
-- 8. RESPONDERS  — patrol/responder units (dashboard)
-- =====================================================================
create table if not exists public.responders (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  type           text,                             -- police | volunteer | medical
  status         text default 'offline',           -- active | responding | offline
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

-- =====================================================================
-- 9. RPC get_active_zones()  — mobile zone source (returns GeoJSON `boundary`)
--    Unions DBSCAN zones + manual zones; SECURITY DEFINER so it works under RLS.
-- =====================================================================
create or replace function public.get_active_zones()
returns table (id uuid, risk_level text, boundary jsonb, source text)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select dz.id, dz.risk_level, st_asgeojson(dz.boundary)::jsonb, coalesce(dz.source, 'dbscan')
  from public.dynamic_zones dz
  where dz.boundary is not null
  union all
  select z.id,
         z.risk_level,
         case when z.polygon_geojson ? 'geometry'
              then z.polygon_geojson -> 'geometry'   -- unwrap GeoJSON Feature -> geometry
              else z.polygon_geojson end,
         'manual'
  from public.zones z
  where z.polygon_geojson is not null;
$$;
grant execute on function public.get_active_zones() to anon, authenticated;

-- =====================================================================
-- 10. BRIDGE 1: trip_pings -> live_locations  (mobile movement -> dashboard)
-- =====================================================================
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
  insert into public.live_locations (user_id, latitude, longitude, source_type, mesh_hop_count, updated_at)
  values (v_user::text, st_y(new.current_location), st_x(new.current_location), 'online', 0, now())
  on conflict (user_id) do update
    set latitude   = excluded.latitude,
        longitude  = excluded.longitude,
        source_type = 'online',
        updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_trip_ping_to_live on public.trip_pings;
create trigger trg_trip_ping_to_live
  after insert on public.trip_pings
  for each row execute function public.sync_trip_ping_to_live_location();

-- =====================================================================
-- 11. BRIDGE 2: trips.status -> 'sos'  =>  create an incident
-- =====================================================================
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
      from public.trip_pings where trip_id = new.id
      order by created_at desc limit 1;
    if v_geom is null then v_geom := new.start_location; end if;
    if v_geom is null then return new; end if;

    select full_name into v_name from public.profiles where id = new.user_id;

    insert into public.incidents (user_id, status, severity, latitude, longitude, source, display_name, notes)
    values (new.user_id::text, 'open', 'high', st_y(v_geom), st_x(v_geom),
            'device', coalesce(v_name, 'SENTRA user'), 'Auto-created from trip SOS');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_trip_sos_to_incident on public.trips;
create trigger trg_trip_sos_to_incident
  after update on public.trips
  for each row execute function public.sos_trip_to_incident();

-- generic updated_at maintenance
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;
drop trigger if exists trg_zones_touch on public.zones;
create trigger trg_zones_touch before update on public.zones
  for each row execute function public.touch_updated_at();
drop trigger if exists trg_trips_touch on public.trips;
create trigger trg_trips_touch before update on public.trips
  for each row execute function public.touch_updated_at();

-- =====================================================================
-- 12. REALTIME  — add tables the dashboard subscribes to (idempotent)
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['incidents','live_locations','zones'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;  -- already in publication
    end;
  end loop;
end $$;

-- =====================================================================
-- 13. ROW LEVEL SECURITY
-- =====================================================================
alter table public.profiles       enable row level security;
alter table public.trips          enable row level security;
alter table public.trip_pings     enable row level security;
alter table public.dynamic_zones  enable row level security;
alter table public.zones          enable row level security;
alter table public.incidents      enable row level security;
alter table public.live_locations enable row level security;
alter table public.responders     enable row level security;

-- ---- Mobile (authenticated, scoped to self) -------------------------
drop policy if exists profiles_self_rw on public.profiles;
create policy profiles_self_rw on public.profiles
  for all to authenticated using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists trips_owner_rw on public.trips;
create policy trips_owner_rw on public.trips
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists trip_pings_owner_ins on public.trip_pings;
create policy trip_pings_owner_ins on public.trip_pings
  for insert to authenticated
  with check (exists (select 1 from public.trips t where t.id = trip_id and t.user_id = auth.uid()));

drop policy if exists trip_pings_owner_sel on public.trip_pings;
create policy trip_pings_owner_sel on public.trip_pings
  for select to authenticated
  using (exists (select 1 from public.trips t where t.id = trip_id and t.user_id = auth.uid()));

-- ---- DEMO-GRADE: dashboard reads/writes as anon (no login yet) ------
-- Replace these with authenticated/authority policies once the dashboard
-- enforces login (see HARDENING block at the bottom).
drop policy if exists zones_anon_all on public.zones;
create policy zones_anon_all on public.zones
  for all to anon, authenticated using (true) with check (true);

drop policy if exists incidents_anon_read on public.incidents;
create policy incidents_anon_read on public.incidents
  for select to anon, authenticated using (true);

drop policy if exists incidents_anon_write on public.incidents;
create policy incidents_anon_write on public.incidents
  for update to anon, authenticated using (true) with check (true);

drop policy if exists incidents_auth_insert on public.incidents;
create policy incidents_auth_insert on public.incidents
  for insert to anon, authenticated with check (true);

drop policy if exists live_locations_anon_read on public.live_locations;
create policy live_locations_anon_read on public.live_locations
  for select to anon, authenticated using (true);

drop policy if exists dynamic_zones_read on public.dynamic_zones;
create policy dynamic_zones_read on public.dynamic_zones
  for select to anon, authenticated using (true);

drop policy if exists responders_anon_read on public.responders;
create policy responders_anon_read on public.responders
  for select to anon, authenticated using (true);

-- NOTE: live_locations writes come only from the SECURITY DEFINER bridge
-- trigger, and dynamic_zones writes come from the backend SERVICE ROLE key —
-- both bypass RLS, so no insert/update policies are needed for them.

-- =====================================================================
-- 14. OPTIONAL SEED (uncomment to give DBSCAN input + a demo incident)
-- =====================================================================
-- insert into public.incidents (user_id, status, severity, latitude, longitude, source, display_name, notes) values
--   ('seed-1','open','high',12.8230,80.0444,'audio','Demo A','Seed incident near SRM gate'),
--   ('seed-2','open','medium',12.8240,80.0455,'manual','Demo B','Seed incident'),
--   ('seed-3','open','low',12.8225,80.0438,'device','Demo C','Seed incident');

-- =====================================================================
-- HARDENING (do later, when the dashboard enforces authority login)
-- =====================================================================
-- 1) Wire useSupabaseAuth into the dashboard render path (gate on a session).
-- 2) Drop the *_anon_* policies above and recreate scoped to authenticated,
--    e.g. an is_authority() predicate on a JWT/role claim:
--      create or replace function public.is_authority() returns boolean
--        language sql stable as $$ select coalesce((auth.jwt() ->> 'role')='authority', false) $$;
--    then: create policy ... for select to authenticated using (is_authority());
-- 3) Restrict zones writes to authority; keep incident ack/resolve to authority.
