# SENTRA / WSF — Database schema

`migrations/0001_unified_schema.sql` is the **single source of truth** that makes
the backend, mobile app, and dashboard share one Supabase project. It was generated
during the audit to reconcile two code generations that originally assumed different
tables.

## How to apply
1. Open your Supabase project → **SQL Editor**.
2. Paste the entire contents of `migrations/0001_unified_schema.sql` and run it.
   (It is idempotent — safe to re-run.)
3. In **Authentication → Providers**, enable **Phone** (with an SMS provider such
   as Twilio) for the mobile OTP login to work.

## What it creates

| Table / object | Used by | Notes |
|---|---|---|
| `profiles` (+ `on_auth_user_created` trigger) | mobile | Auto-filled from OTP signup `full_name` + phone |
| `trips` | mobile | Escort sessions; `status` drives SOS |
| `trip_pings` | mobile | Location pings (PostGIS Point) |
| `dynamic_zones` | backend | DBSCAN output; written with the service-role key |
| `zones` | dashboard | Manual zones (GeoJSON); dashboard auto-seeds defaults |
| `incidents` | dashboard + backend | lat/lon floats **and** a generated `location` geometry |
| `live_locations` | dashboard | Latest position per user; fed by the bridge trigger |
| `responders` | dashboard | Patrol units |
| `get_active_zones()` RPC | mobile | Returns zone `boundary` as GeoJSON |

## Live bridges (so mobile data appears on the dashboard)
- **`trip_pings` INSERT → `live_locations` upsert** — moving users show on the map.
- **`trips.status='sos'` → new `incidents` row** — SOS appears in the incident feed.

## ⚠️ Security
The dashboard has no login gate yet, so it queries Supabase as the **anon** role.
The dashboard-facing tables therefore use **permissive anon RLS policies** — this is
**demo-grade**. See the `HARDENING` block at the bottom of the SQL file for how to
lock it down once you add authority login to the dashboard.
