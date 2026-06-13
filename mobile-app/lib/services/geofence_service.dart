import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Geofencing + trip lifecycle (pings, route-drift detection).
///
/// This service no longer owns the raw location stream. All location fixes
/// arrive pre-filtered from [LocationService] via [handleLocationFix], so there
/// is exactly one accuracy/jump gate in the app. Geofence ENTER/EXIT events
/// still come straight from the plugin, which is fine — they are zone crossings,
/// not coordinates we display.
class GeofenceService {
  static final GeofenceService _instance = GeofenceService._internal();
  factory GeofenceService() => _instance;
  GeofenceService._internal();

  // ── Trip state ─────────────────────────────────────────────────────────────
  Timer? _driftTimer;
  List<Position>? _expectedRoute;
  String? _activeTripId;

  final SupabaseClient _supabase = Supabase.instance.client;

  // ── Callbacks ──────────────────────────────────────────────────────────────
  Function()? onDriftAlert;
  Function(bg.GeofenceEvent)? onDangerZoneTrigger;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Registers the geofence-event listener. The plugin itself is configured and
  /// started by [LocationService.initialize], which must run first so that
  /// addGeofences() (in [setupPolygons]) has a ready plugin to talk to.
  Future<void> initialize() async {
    bg.BackgroundGeolocation.onGeofence(_onGeofence);
  }

  // ── Geofence polygon setup ─────────────────────────────────────────────────

  void setupPolygons(List<dynamic> activeZones) async {
    await bg.BackgroundGeolocation.removeGeofences();
    final List<bg.Geofence> bgGeofences = [];
    int index = 0;

    for (final zone in activeZones) {
      if (zone['boundary'] == null) continue;

      final rawB = zone['boundary'];
      final Map<String, dynamic> bMap = rawB is String
          ? jsonDecode(rawB) as Map<String, dynamic>
          : rawB as Map<String, dynamic>;

      if (bMap['type'] != 'Polygon') continue;

      final List<dynamic> ringData = bMap['coordinates'][0] as List<dynamic>;
      final List<List<double>> vertices = ringData
          .map<List<double>>(
              (pt) => [pt[1].toDouble(), pt[0].toDouble()])
          .toList();

      bgGeofences.add(bg.Geofence(
        identifier: 'danger_zone_${index++}',
        vertices: vertices,
        notifyOnEntry: true,
        notifyOnExit: true,
        extras: {'risk_level': zone['risk_level'] ?? 'red'},
      ));
    }

    if (bgGeofences.isNotEmpty) {
      await bg.BackgroundGeolocation.addGeofences(bgGeofences);
    }
  }

  // ── Trip tracker ───────────────────────────────────────────────────────────

  Future<void> startTripTracker(String tripId, List<Position> route) async {
    _activeTripId = tripId;
    _expectedRoute = route;
    _driftTimer?.cancel();
  }

  Future<void> stopTripTracker() async {
    _activeTripId = null;
    _expectedRoute = null;
    _driftTimer?.cancel();
  }

  void cancelDriftTimer() => _driftTimer?.cancel();

  // ── Filtered-fix handler ─────────────────────────────────────────────────

  /// Called by [LocationService] on every ACCEPTED (already-filtered) fix.
  /// Records a trip ping and runs route-drift detection. Coordinates are trusted
  /// here — all accuracy/jump filtering happened upstream in LocationService.
  void handleLocationFix(double lat, double lng) {
    if (_activeTripId == null ||
        _expectedRoute == null ||
        _expectedRoute!.isEmpty) {
      return;
    }

    final String? userId = _supabase.auth.currentUser?.id;
    if (userId != null) {
      _supabase.from('trip_pings').insert({
        'trip_id':          _activeTripId,
        'current_location': 'SRID=4326;POINT($lng $lat)',
      }).catchError((Object e) {});
    }

    final double drift = _minDistanceToRoute(lat, lng, _expectedRoute!);
    if (drift > 50.0) {
      if (_driftTimer == null || !_driftTimer!.isActive) {
        _driftTimer = Timer(const Duration(seconds: 30), () {
          onDriftAlert?.call();
        });
      }
    } else {
      _driftTimer?.cancel();
    }
  }

  // ── Private handlers ───────────────────────────────────────────────────────

  void _onGeofence(bg.GeofenceEvent event) =>
      onDangerZoneTrigger?.call(event);

  // ── Route geometry helpers ─────────────────────────────────────────────────

  double _minDistanceToRoute(
      double lat, double lng, List<Position> route) {
    double minDist = double.infinity;
    for (int i = 0; i < route.length - 1; i++) {
      final double d = _distanceToSegment(
        lat, lng,
        route[i].lat.toDouble(),   route[i].lng.toDouble(),
        route[i + 1].lat.toDouble(), route[i + 1].lng.toDouble(),
      );
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  double _distanceToSegment(
    double px, double py,
    double ax, double ay,
    double bx, double by,
  ) {
    const double latToM = 111320.0;
    final double lngToM = 111320.0 * math.cos(py * math.pi / 180.0);

    final double x  = (px - ax) * latToM;
    final double y  = (py - ay) * lngToM;
    final double dx = (bx - ax) * latToM;
    final double dy = (by - ay) * lngToM;

    final double lenSq = dx * dx + dy * dy;
    double xx, yy;

    if (lenSq == 0) {
      xx = ax * latToM;
      yy = ay * lngToM;
    } else {
      final double t = ((x * dx + y * dy) / lenSq).clamp(0.0, 1.0);
      xx = ax * latToM + t * dx;
      yy = ay * lngToM + t * dy;
    }

    final double ddx = (px * latToM) - xx;
    final double ddy = (py * lngToM) - yy;
    return math.sqrt(ddx * ddx + ddy * ddy);
  }
}
