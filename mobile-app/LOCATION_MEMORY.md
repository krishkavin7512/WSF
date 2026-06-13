# LOCATION_MEMORY.md — SENTRA mobile location subsystem

> Living reference for everything involved in detecting, filtering, storing and
> consuming the device location. Built before the GPS rebuild; updated after.

---

## 1. Location-related packages (pubspec.yaml)

| Package | Version | Role | Status after rebuild |
|---|---|---|---|
| `flutter_background_geolocation` | ^4.15.2 | Native background GPS stream, geofencing, motion activity. The robust, battle-tested engine. | **KEPT — the single location source** |
| `geolocator` | ^10.1.0 | Alternative location plugin. **Never called from Dart** (only a comment referenced it). Still registered natively (`FlutterGeolocator: Attaching Geolocator to activity` in logcat). | **REMOVED from pubspec** (dead weight + latent conflict) |
| `mapbox_maps_flutter` | 2.17.0 | Map rendering + blue-dot `LocationComponent` (reads OS location directly, independent of our stream). | Kept (map only) |
| `permission_handler` | ^11.3.0 | Runtime permission requests (location, mic). | Kept |

**Conflict assessment:** Two location plugins were declared. `geolocator` was
unused in Dart but still initialised natively at app start. It was not the
*direct* cause of the Bangalore jump (it never produced a fix the app read), but
it is exactly the kind of latent dual-source ambiguity the rebuild eliminates.
`flutter_background_geolocation` is the only package wired into trips, drift,
geofencing and the beacon, so it is the natural single source of truth.

---

## 2. Location variables in home_screen.dart

| Variable | Type | Set where | Read where |
|---|---|---|---|
| `_cameraLat` / `_cameraLng` | `static const double` (17.3422 / 78.3663) | Never (compile-time const) | `MapWidget.cameraOptions` initial center only — decoupled from state so `setState` never re-applies camera |
| `_startLat` / `_startLng` | `double` (default Lords 17.3422 / 78.3663) | (a) `LocationService.onLocationUpdate` (live, filtered) — primary; (b) search "Set as start" (explicit user action — the only sanctioned non-GPS writer) | Routing origin, heatmap city detection (`_loadHeatmap`), SOS message coords, proximity search `proximity=` param |
| `_destLat` / `_destLng` | `double?` | Destination search selection | Routing destination, pin drop |

---

## 3. Location update callbacks / listeners (whole codebase)

| File · function | What it does with the fix |
|---|---|
| `location_service.dart · _onLocation` | **THE filtered entry point.** Applies accuracy gate + jump gate, then: updates `_lastLat/_lng`, fires `onLocationUpdate`, writes `live_locations`, forwards to `GeofenceService.handleLocationFix`. |
| `geofence_service.dart · handleLocationFix` | Receives already-filtered (lat,lng). Inserts `trip_pings` and runs route-drift detection. **No gating here.** |
| `geofence_service.dart · _onGeofence` | Fires `onDangerZoneTrigger` on geofence ENTER/EXIT (zone safety banner). |
| `home_screen.dart · onLocationUpdate` (callback) | Sets `_startLat/_startLng`; centers the camera once on first valid fix. |

---

## 4. Where the map camera moves on location

| Trigger | Mechanism | Location-driven? |
|---|---|---|
| Initial render | `MapWidget.cameraOptions` = `_cameraLat/_cameraLng` consts | No (fixed) |
| First valid fix | `onLocationUpdate` → one-time `flyTo` user position | **Yes — only via accepted fix** |
| Route drawn | `_fetchAndDrawRoute` → `cameraForCoordinateBounds` + `flyTo` | No (user action) |
| Blue dot | Mapbox `LocationComponent` (its own OS reader) | Independent of our stream (cosmetic) |

---

## 5. Android permissions (AndroidManifest.xml)

`ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`,
`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `RECORD_AUDIO`, `INTERNET`,
`READ_PHONE_STATE`.

---

## 6. Complete flow: "GPS fires" → "map updates"

```
OS fused provider
   │  raw fix (lat,lng,accuracy,heading,speed)
   ▼
flutter_background_geolocation  (HIGH accuracy, distanceFilter 10m)
   │  bg.Location
   ▼
LocationService._onLocation        ◀── THE single gate
   │   CHECK 1: accuracy ≤ 100m   else reject
   │   CHECK 2: jump  ≤ 50km      else reject (5-strike re-anchor)
   ▼ (accepted only)
   ├─ _lastLat/_lng           (getCurrentLocation cache)
   ├─ onLocationUpdate(lat,lng,heading,speed)
   │      └─ HomeScreen: setState _startLat/_startLng (+ one-time camera center)
   ├─ live_locations upsert   (Supabase → dashboard beacon)
   └─ GeofenceService.handleLocationFix(lat,lng)
          ├─ trip_pings insert  (→ DB bridge → dashboard)
          └─ drift detection    (→ onDriftAlert)
```

---

## 7. Root-cause diagnosis of the Bangalore jump

- The phone is physically in Hyderabad (17.3422, 78.3663). It correctly shows
  that for 5–6 s (cold-start GPS), then jumps to Bangalore (~12.97, 77.6).
- `live_locations` was **empty** when queried at rest → no server-side seed row.
  The bad coordinate is **written live by the app during a session**.
- A clean uninstall/reinstall did **not** fix it → not the plugin's local SQLite
  cache; the bad fix comes from the **OS fused location provider**.
- Mechanism: **WiFi-based positioning.** A nearby access point is registered in
  Google's location database at an old Bangalore address. The fused provider
  returns that fix with a *tight* reported accuracy (~20–50 m), so a pure
  accuracy threshold cannot catch it.
- Pre-rebuild, the only gate was accuracy (100 m). The Bangalore WiFi fix passed
  it and was written straight to `live_locations` and `_startLat/_startLng`.

**Fix:** add a second, physics-based gate. No real GPS stream moves ~500 km
between pings seconds apart, so any jump > 50 km from the last confirmed fix is
rejected. Centralise both gates in one `LocationService` so no consumer can ever
see an unfiltered fix.

---

## 8. Rebuild delta (what changed)

### Deleted
- **`geolocator` dependency** removed from `pubspec.yaml` (was unused in Dart).
- From `geofence_service.dart`: the entire raw-location path —
  `_onLocation` listener registration, the accuracy gate, the (older 150 km)
  teleport gate, `_lastValidLat/_lng`, `_consecutiveTeleportRejects`,
  `lastValidLocation` getter, `onLocationUpdate` callback, the `live_locations`
  upsert, `_haversineKm`, and the `bg...ready()/start()` config. GeofenceService
  no longer owns or filters location.
- From `home_screen.dart`: the old `geofenceService.onLocationUpdate` handler
  (which re-checked accuracy and set `_startLat/_startLng`).

### Added
- **`lib/services/location_service.dart`** — new singleton, the sole location
  source. Methods: `initialize()`, `dispose()`, `getCurrentLocation()`,
  `clearLocation()`, and the `onLocationUpdate(lat,lng,heading,speed)` callback.
  Owns `bg` config/`ready`/`start`, applies CHECK 1 (accuracy ≤ 100 m) and
  CHECK 2 (jump ≤ 50 km, 5-strike re-anchor), writes the `live_locations`
  beacon (`source_type: 'gps'`), and forwards accepted fixes to GeofenceService.
- In `geofence_service.dart`: `handleLocationFix(lat,lng)` — receives
  pre-filtered fixes for trip-ping recording + drift detection. `initialize()`
  now only registers the geofence listener.
- In `home_screen.dart`: `LocationService().onLocationUpdate` sets
  `_startLat/_startLng` and centers the camera once (`_hasCenteredOnUser`).
  `LocationService` is initialised before `GeofenceService` (ready/start order).

### Why the old approach failed
A single accuracy gate cannot distinguish a real 30 m GPS fix from a 30 m WiFi
fix geolocated to the wrong city. Without a distance/physics check, the Bangalore
WiFi fix passed straight through. Splitting ownership (two services both touching
the raw stream) also risked double-writes and divergent filtering. The rebuild
makes one service the only place a fix is validated.

### Preserved (unchanged behaviour)
Trip lifecycle (`startTripTracker`/`stopTripTracker`), SOS, drift detection,
geofence ENTER/EXIT banners, audio sentinel. The user-initiated "Set as start"
search remains the one sanctioned non-GPS writer of `_startLat/_startLng`.
