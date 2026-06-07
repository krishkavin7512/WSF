# SENTRA / WSF — Feature Reality Audit

> Audit date: 2026-06-07 · Branch: `audit-fixes` · Method: **static code reading only** (nothing built or run).
> Status legend: ✅ Working · ⚠️ Partial/Buggy · ❌ Not Implemented
>
> **Headline:** This fork merged **two incompatible generations** that never agree on the database.
> - **Mobile + Backend** = "SENTRA V2" (SRM Chennai, phone-OTP, PostGIS, tables `trips`/`trip_pings`/`profiles`/`dynamic_zones`/`incidents`, RPC `get_active_zones`).
> - **Dashboard** = "Authority/TravelMate V1" (Vellore/VIT, Google OAuth, tables `user_profiles`/`live_locations`/`incidents`/`zones`/`responders`).
> They share only the name `incidents` — and even that differs (dashboard uses lat/lon floats; backend uses a PostGIS `location` column). **No live data path connects mobile → dashboard.**

---

## A. The 6 "Core Features" from the README

| # | Feature | Status | Evidence (files / functions) | What's needed to finish |
|---|---------|--------|------------------------------|--------------------------|
| 1 | **Dynamic Threat Intelligence (DBSCAN zones)** | ⚠️ Partial | [zone_generator.py](WSF/backend-ai/tasks/zone_generator.py) `generate_dynamic_zones()` — real DBSCAN (haversine, `min_samples=3`), `concave_hull(ratio=0.3)`, buffer, writes `dynamic_zones.boundary` as EWKT. | Runs **only as a manual script** (`python tasks/zone_generator.py`) — **no APScheduler** despite docs. Needs a populated `incidents` table. **Mismatch vs README:** epsilon is **50 m** (README says 250 m), buffer is **~15 m** (README says 50 m). "Shifts by time of day" is **not implemented** — `/zones` ignores `simulated_hour`. KDE time-decay and OSM dark-mode proxies are **absent**. |
| 2 | **SafeNav tactical routing** | ⚠️ Partial | [safenav.py](WSF/backend-ai/routes/safenav.py) `find_safest_route()` / `analyze_route_safety()`; endpoint `POST /get-safe-route` in [main.py](WSF/backend-ai/main.py); consumed by [api_service.dart](WSF/mobile-app/lib/services/api_service.dart) + rendered in [home_screen.dart](WSF/mobile-app/lib/screens/home_screen.dart) `_fetchAndDrawRoute()`. | Core works: fetches Mapbox **walking** alternatives, scores each against `dynamic_zones` (shapely `distance`/`intersects`, ~50 m proximity), returns `is_route_safe` (score ≥ 50); Flutter draws red/blue polyline. **Overstated:** it only *ranks the alternatives Mapbox already returns* — it does **not** "physically bypass" zones or apply street avoidance weights (the Architecture's Valhalla/GraphHopper avoidance does not exist). Needs Mapbox token + populated zones. |
| 3 | **Drift Protocol (autonomous geofencing)** | ✅ Working | [geofence_service.dart](WSF/mobile-app/lib/services/geofence_service.dart) `_onLocation()` → cross-track error `_distanceToSegment()` (equirectangular), `>50 m` starts 30 s timer → `onDriftAlert` → `DriftSosOverlay` (15 s, heavy haptics) in [home_screen.dart](WSF/mobile-app/lib/screens/home_screen.dart); no-response writes `trips.status='sos'`. Uses `flutter_background_geolocation` (OS-tier). | Functionally complete. Requires: active trip (`_activeTripId`, `_expectedRoute`), `trips`/`trip_pings` tables, and the licensed BG-geo plugin configured for release builds. |
| 4 | **Edge-Audio Sentinel (YAMNet)** | ✅ Working | [audio_sentinel_service.dart](WSF/mobile-app/lib/services/audio_sentinel_service.dart) — `tflite_flutter` loads `assets/sentinel_audio.tflite`, `record` streams PCM16@16 kHz, buffers 15 600 samples / 900 ms throttle, runs `[1,15600]→[1,521]`, top-5 > **0.15** vs danger keywords → `onDangerDetected`. Assets present (`sentinel_audio.tflite`, `labels.txt`). | On-device inference is real. **Caveat:** it listens **continuously** — there is **no low-power DSP/decibel gate** (contradicts both Architecture.md *and* the project's own `.cursorrules` "no 24/7 background audio"). The `.tflite` being a valid YAMNet can't be confirmed without running. |
| 5 | **Hardware Override (3× Volume-Down)** | ✅ Working (Android only) | [MainActivity.kt](WSF/mobile-app/android/app/src/main/kotlin/com/example/mobile_app/MainActivity.kt) `EventChannel("wsf/hardware_buttons")` emits on `KEYCODE_VOLUME_DOWN`; [home_screen.dart](WSF/mobile-app/lib/screens/home_screen.dart) `_onVolumeDownPressed()` counts ≥3 presses/2 s → `_triggerImmediateSosBypass()` cancels overlays + writes `trips.status='sos'`. | Works on Android. **Caveat:** README says it writes "live WKT coordinates" — the bypass only sets `status='sos'` (coords come from the existing `trips` row). iOS is roadmap (not implemented). |
| 6 | **Enterprise Identity & Tactical Dashboard** | ⚠️ Partial | Split into sub-features below (6a–6f). | See rows below. |

### Feature 6 broken out

| # | Sub-feature | Status | Evidence | What's needed |
|---|-------------|--------|----------|---------------|
| 6a | Uber-style design system | ✅ Working | [sentra_design.dart](WSF/mobile-app/lib/theme/sentra_design.dart) (`SentraDesign`) used throughout mobile UI. | — |
| 6b | **Mobile OTP/SMS auth (E.164)** | ✅ Working | [login_screen.dart](WSF/mobile-app/lib/screens/login_screen.dart) `_sendOtp()`/`_verifyOtp()` via `signInWithOtp(phone:)` + `verifyOTP(type: sms)`; `_formatPhoneE164()`. | Requires Supabase **phone provider (Twilio/etc.) enabled** in the project — otherwise OTP send fails. |
| 6c | **`profiles` table + auto-mirror trigger** | ❌ Not Implemented | Mobile *expects* it: `signInWithOtp(data:{full_name})` and reads `profiles.full_name` ([home_screen.dart](WSF/mobile-app/lib/screens/home_screen.dart) `_showProfileSheet()`). **No SQL trigger or `profiles` table exists in the repo.** Recovered V1 schema uses a different table (`user_profiles`) and has **no auth trigger**. | Generate a `profiles` table + `on auth.users insert` trigger (Phase 6 deliverable). |
| 6d | Dashboard realtime incidents | ⚠️ Partial | [useRealtimeIncidents.ts](WSF/web-dashboard/src/hooks/useRealtimeIncidents.ts) — fetch + `postgres_changes` subscribe on `incidents`, ack/resolve writers. Solid code. | Needs an `incidents` table whose columns match (recovered `001_complete_schema.sql` matches). **But the dashboard's main page passes hardcoded `REAL_INCIDENTS`, not this hook** — so it isn't wired into the live view yet. |
| 6e | Dashboard realtime location tracking | ⚠️ Partial (broken link) | [useRealtimeLocations.ts](WSF/web-dashboard/src/hooks/useRealtimeLocations.ts) subscribes to **`live_locations`**; rendered as Mapbox beacons in [MapView.tsx](WSF/web-dashboard/src/components/MapView.tsx). | Dashboard side works **if** a `live_locations` table is fed — but **the mobile app writes `trip_pings`, never `live_locations`** → end-to-end link is broken. Currently shows recovered mock `REAL_USER_LOCATIONS`, not live data. |
| 6f | **"Ghost Tracking" (dashed velocity-vector projection)** | ❌ Not Implemented | Only `source_type`/`mesh_hop_count` fields + mock data exist ([types.ts](WSF/web-dashboard/src/types.ts)). No dashed-track / velocity-vector / dead-reckoning code anywhere (`ghost`/`velocity` appear only in README & docs). | Build the projection logic from scratch (per your "catalog, don't scaffold" rule, left as ❌). |

---

## B. Other claims made in the README / Architecture / pitch

| Claim | Status | Notes |
|-------|--------|-------|
| Manual SOS button → "automated dispatch" | ⚠️ Partial | The SOS nav button calls `_handleSosSequence()` → 10 s countdown → **opens the SMS app to a hardcoded number `+91 9940903891`** ([home_screen.dart](WSF/mobile-app/lib/screens/home_screen.dart) `_launchSmsApp()`). Not an automated server dispatch. |
| Dashboard "Dispatch Patrol" workflow (ack → en route → dispatched → push) | ❌ Not Implemented | [MapView.tsx](WSF/web-dashboard/src/components/MapView.tsx) "Dispatch Patrol" button is a `window.alert()` with a `// TODO: Call dispatch API when implemented`. |
| FCM "Security has been dispatched" push to victim | ❌ Not Implemented | No Firebase/FCM/messaging code anywhere (only transitive lockfile hits). |
| Backend "Trip Watchdog" (server monitors dropped pings) | ❌ Not Implemented | No backend code reads/monitors `trip_pings`; no scheduler/watchdog. |
| PostGIS "source of truth" everywhere | ⚠️ Partial | Mobile/backend use EWKT/PostGIS-style strings; the **recovered dashboard schema uses `earthdistance`/lat-lon floats, not PostGIS**. Inconsistent. |
| Dashboard requires authority login | ❌ Not Implemented | `useSupabaseAuth` (Google OAuth) is **defined but never imported** into the render path; [page.tsx](WSF/web-dashboard/src/app/page.tsx) → `DashboardPage` renders **with no auth guard**. |
| Time-weighted KDE decay | ❌ Not Implemented | Claimed in Architecture.md only. |
| OSM dark-mode "Yellow Zone" proxies | ❌ Not Implemented | Claimed in Architecture.md only. |

## C. Roadmap items (README explicitly lists as future — all ❌, as expected)

| Roadmap item | Status |
|---|---|
| Police FIR data integration | ❌ Not Implemented |
| Crowd-sourced incident reporting | ❌ Not Implemented |
| Smartwatch / wearable SOS | ❌ Not Implemented |
| Predictive KDE time-decay scoring | ❌ Not Implemented |
| AI video anomaly detection (CCTV) | ❌ Not Implemented |
| iOS Volume-Button hardware bridge | ❌ Not Implemented (honestly noted as Android-only) |

---

## D. Cross-cutting infrastructure gaps (not "features," but block running)

| Item | Status | Notes |
|------|--------|-------|
| Web dashboard `src/data/` (velloreRealData, crimeZones, …) | ❌ Missing (🟢 recoverable from git `5f2f564^`) | 10 files import it; **dashboard won't compile** until restored. |
| DB schema / migrations | ❌ Missing from working tree (🟢 V1 recoverable from git `67acfe4^`) | Recovered `001_complete_schema.sql` matches the **dashboard** exactly but lacks V2 tables (`trips`, `trip_pings`, `profiles`, `dynamic_zones`) and RPC `get_active_zones`. |
| `get_active_zones` RPC (mobile zone source) | ❌ Not defined | [api_service.dart](WSF/mobile-app/lib/services/api_service.dart) calls `supabase.rpc('get_active_zones')`; no SQL defines it. |
| Backend `requests` dependency | ⚠️ Missing from `requirements.txt` | Imported in safenav.py; app crashes at import. (Safe Phase-3 fix.) |
| `.env` / `.env.example` for backend & mobile | ❌ Missing | Only the dashboard ships `.env.example`. |
| Docker setup | ⚠️ Broken | Wrong env var (`SUPABASE_ANON_KEY` vs required `SUPABASE_SERVICE_ROLE_KEY`), missing `MAPBOX_ACCESS_TOKEN`, Python 3.9 vs 3.10+ code. |
| Secrets in git history | ⚠️ Security | Commit `c1468a9` committed `web-dashboard/.env.local` with **real** Supabase anon JWT + Mapbox tokens. Rotate them. |

---

## E. One-line truth table (quick scan)

```
DBSCAN zone generation .............. ⚠️  real script, wrong constants vs README, manual-only
SafeNav routing ..................... ⚠️  ranks Mapbox alts (no true avoidance)
Drift Protocol geofencing ........... ✅  implemented
Edge-Audio YAMNet sentinel .......... ✅  implemented (continuous, no DSP gate)
3× Volume-Down override ............. ✅  implemented (Android only)
Mobile OTP/SMS auth ................. ✅  implemented (needs Supabase phone provider)
profiles table + trigger ............ ❌  expected by code, not in repo
Dashboard realtime incidents ........ ⚠️  hook works, not wired to live view
Dashboard realtime location ......... ⚠️  reads live_locations; mobile writes trip_pings (broken link)
Ghost Tracking ...................... ❌  not implemented
Dispatch workflow / FCM push ........ ❌  not implemented (alert() + TODO)
Trip Watchdog (backend) ............. ❌  not implemented
KDE decay / OSM proxies ............. ❌  not implemented
```
