import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'geofence_service.dart';

/// CHECK 1 — reject any fix whose reported horizontal accuracy is worse than
/// this (metres). Network/WiFi/cell fixes are typically 500–2000 m; real GPS is
/// 5–20 m. 100 m keeps GPS, drops the rest.
const double kMaxAccuracyMetres = 100.0;

/// CHECK 2 — reject any fix more than this many km from the last confirmed fix.
/// A real GPS stream cannot physically teleport; a large jump means the OS mixed
/// in a WiFi/cell position geolocated to the wrong city (which can still report
/// a tight accuracy and pass CHECK 1). 50 km is far larger than any plausible
/// movement between two pings yet far smaller than the ~500 km Hyderabad↔
/// Bangalore error, so it cleanly rejects the bug while never blocking real travel.
const double kMaxJumpKm = 50.0;

/// If this many consecutive fixes all land far from the current anchor, the user
/// genuinely travelled a long distance (or the very first fix anchored us to a
/// wrong location), so accept and re-anchor rather than getting stuck forever.
const int kReanchorThreshold = 5;

/// The ONE and ONLY location source for the app.
///
/// Wraps `flutter_background_geolocation`'s raw stream and applies two gates
/// (accuracy + impossible-jump) before any consumer sees a fix. Everything that
/// needs the device position — the map camera, `_startLat/_startLng`, the
/// Supabase live beacon, trip pings and drift detection — is fed from here, so a
/// bad OS fix (e.g. a WiFi position geolocated to another city) can never leak
/// through to the rest of the app.
class LocationService {
  LocationService._internal();
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;

  final SupabaseClient _supabase = Supabase.instance.client;

  // Last confirmed-good fix. Null until the first accepted fix this session.
  // Never seeded with a hardcoded city.
  double? _lastLat;
  double? _lastLng;

  // Consecutive fixes rejected by the jump gate; resets to 0 on every accept.
  int _consecutiveFarRejects = 0;

  // Guards against double initialize() (ready() must be called exactly once).
  bool _started = false;

  /// Fires on every ACCEPTED fix (after both gates pass). The UI must set its
  /// camera / position state from here and from nowhere else.
  void Function(double lat, double lng, double heading, double speed)?
      onLocationUpdate;

  // ── Public API ───────────────────────────────────────────────────────────

  /// Starts background location tracking. Safe to call more than once.
  Future<void> initialize() async {
    if (_started) return;

    bg.BackgroundGeolocation.onLocation(_onLocation, _onLocationError);

    await bg.BackgroundGeolocation.ready(bg.Config(
      desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
      distanceFilter: 10.0,
      stopOnTerminate: true,
      startOnBoot: false,
      locationAuthorizationRequest: 'Always',
      debug: false,
      logLevel: bg.Config.LOG_LEVEL_OFF,
    ));

    // We deliberately do NOT call getCurrentPosition() — it can replay the
    // plugin's last-persisted fix from a previous session/city. We wait for a
    // live fix instead.
    await bg.BackgroundGeolocation.start();
    _started = true;
  }

  /// Stops tracking and clears in-memory state. Call on logout.
  Future<void> dispose() async {
    await bg.BackgroundGeolocation.stop();
    bg.BackgroundGeolocation.removeListeners();
    _started = false;
    _lastLat = null;
    _lastLng = null;
    _consecutiveFarRejects = 0;
  }

  /// The last confirmed-good location, or null if none yet this session.
  ({double lat, double lng})? getCurrentLocation() {
    if (_lastLat == null || _lastLng == null) return null;
    return (lat: _lastLat!, lng: _lastLng!);
  }

  /// Removes this user's beacon from `live_locations` (logout / session end).
  Future<void> clearLocation() async {
    final String? userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;
    await _supabase.from('live_locations').delete().eq('user_id', userId);
  }

  // ── Private ──────────────────────────────────────────────────────────────

  void _onLocationError(bg.LocationError error) {
    print('[LocationService] location error: ${error.code} ${error.message}');
  }

  void _onLocation(bg.Location location) {
    final double lat      = location.coords.latitude;
    final double lng      = location.coords.longitude;
    final double accuracy = location.coords.accuracy;
    final double heading  = location.coords.heading;
    final double speed    = location.coords.speed;

    print('[LocationService] fix lat=$lat lng=$lng accuracy=${accuracy}m');

    // ── CHECK 1 — Accuracy gate ──────────────────────────────────────────────
    // accuracy is the OS-reported horizontal error radius (m). A negative value
    // means "unknown". Anything worse than the threshold is a network/cell fix.
    if (accuracy < 0 || accuracy > kMaxAccuracyMetres) {
      print('Rejecting low-accuracy fix: ${accuracy}m');
      return;
    }

    // ── CHECK 2 — Impossible-jump gate ───────────────────────────────────────
    if (_lastLat != null && _lastLng != null) {
      final double jumpKm = _haversineKm(_lastLat!, _lastLng!, lat, lng);
      if (jumpKm > kMaxJumpKm) {
        _consecutiveFarRejects++;
        print('Rejecting impossible jump: ${jumpKm.toStringAsFixed(1)}km from '
            'last fix (reject #$_consecutiveFarRejects)');
        if (_consecutiveFarRejects < kReanchorThreshold) {
          return;
        }
        print('Re-anchoring after $kReanchorThreshold consecutive far fixes.');
      }
    }
    _consecutiveFarRejects = 0;

    // ── ACCEPTED ─────────────────────────────────────────────────────────────
    _lastLat = lat;
    _lastLng = lng;

    // 1. Notify the UI (map camera + _startLat/_startLng).
    onLocationUpdate?.call(lat, lng, heading, speed);

    // 2. Update the Supabase live beacon (dashboard map).
    _writeBeacon(lat, lng, heading, speed, accuracy);

    // 3. Feed trip-ping recording + route-drift detection.
    GeofenceService().handleLocationFix(lat, lng);
  }

  void _writeBeacon(
      double lat, double lng, double heading, double speed, double accuracy) {
    final String? userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;
    _supabase.from('live_locations').upsert(
      {
        'user_id':        userId,
        'latitude':       lat,
        'longitude':      lng,
        'heading':        heading,
        'speed':          speed,
        'accuracy':       accuracy,
        'updated_at':     DateTime.now().toUtc().toIso8601String(),
        'source_type':    'gps',
        'mesh_hop_count': 0,
      },
      onConflict: 'user_id',
    ).catchError((Object e) {
      // Non-fatal — the dashboard keeps the last persisted position.
    });
  }

  /// Great-circle distance between two lat/lng points, in kilometres.
  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const double earthRadiusKm = 6371.0;
    final double dLat = (lat2 - lat1) * math.pi / 180.0;
    final double dLng = (lng2 - lng1) * math.pi / 180.0;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusKm * c;
  }
}
