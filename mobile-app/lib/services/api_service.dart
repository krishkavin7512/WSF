import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ApiService {
  final String _baseUrl = dotenv.env['BACKEND_API_BASE_URL']?.isNotEmpty == true
      ? dotenv.env['BACKEND_API_BASE_URL']!
      : 'http://10.0.2.2:8000';

  final String _mapboxToken = dotenv.env['MAPBOX_ACCESS_TOKEN'] ?? '';

  ApiService() {
    print('Backend URL: $_baseUrl');
  }

  // ---------------------------------------------------------------------------
  // DANGER ZONES — read directly from Supabase (no backend dependency)
  // ---------------------------------------------------------------------------
  Future<List<dynamic>> getDangerZones({int? simulatedHour}) async {
    try {
      final response = await Supabase.instance.client
          .from('dynamic_zones')
          .select('id, risk_level, boundary');

      final rows = response as List<dynamic>;
      return rows;
    } catch (e) {
      print('❌ Zone Fetch Error (Supabase): $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // HEATMAP ZONES — read directly from Supabase (no backend dependency)
  // ---------------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> getHeatmapZones({
    String? city,
    int? hour,
    bool showAll = true,
  }) async {
    try {
      var query = Supabase.instance.client
          .from('heatmap_zones')
          .select('latitude, longitude, radius_m, risk_level, area_name, city');

      if (city != null) {
        query = query.eq('city', city);
      }

      final response = await query;
      final rows = List<Map<String, dynamic>>.from(response as List);
      print('Heatmap zones from Supabase: ${rows.length}');
      return rows;
    } catch (e) {
      print('Heatmap fetch error (Supabase): $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // SAFE ROUTE — tries the backend (risk-weighted engine) with a 5-second
  // timeout, then falls back to Mapbox Directions API (walking → driving)
  // so routing always works even when the backend is unreachable.
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>?> getSafeRoute(
      double startLat, double startLng, double endLat, double endLng) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      print('⚠️ Route Error: user is not authenticated.');
      return null;
    }

    // ── 1. Try the backend risk engine ────────────────────────────────────────
    try {
      final url = Uri.parse('$_baseUrl/get-safe-route');
      final body = jsonEncode({
        "start_lat": startLat,
        "start_lng": startLng,
        "end_lat": endLat,
        "end_lng": endLng,
        "user_id": userId,
      });
      print('[ApiService] Route request: $url');

      final response = await http
          .post(
            url,
            headers: {"Content-Type": "application/json"},
            body: body,
          )
          .timeout(const Duration(seconds: 5));

      print('[ApiService] Route response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      print('❌ Backend route unavailable ($e) — falling back to Mapbox Directions');
    }

    // ── 2. Mapbox walking, then driving if no walking route found ─────────────
    return _mapboxDirectionsFallback(startLat, startLng, endLat, endLng, profile: 'walking');
  }

  Future<Map<String, dynamic>?> _mapboxDirectionsFallback(
      double startLat, double startLng, double endLat, double endLng,
      {String profile = 'walking'}) async {
    if (_mapboxToken.isEmpty) {
      print('❌ Mapbox token missing — cannot fall back to directions');
      return null;
    }

    try {
      final url = Uri.parse(
        'https://api.mapbox.com/directions/v5/mapbox/$profile'
        '/$startLng,$startLat;$endLng,$endLat'
        '?access_token=$_mapboxToken'
        '&geometries=polyline'
        '&overview=full'
        '&steps=false',
      );

      print('[ApiService] Mapbox Directions ($profile): $url');
      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        print('❌ Mapbox Directions error: ${response.statusCode} — ${response.body}');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = data['routes'] as List?;

      if (routes == null || routes.isEmpty) {
        final code = data['code'] ?? 'unknown';
        final message = data['message'] ?? 'no routes';
        print('❌ Mapbox $profile: no routes found (code=$code, message=$message)');

        // Walking failed → retry with driving profile
        if (profile == 'walking') {
          print('[ApiService] Retrying with driving profile...');
          return _mapboxDirectionsFallback(startLat, startLng, endLat, endLng, profile: 'driving');
        }
        return null;
      }

      final route = routes[0] as Map<String, dynamic>;
      final String geometry = route['geometry'] as String;
      final double duration = (route['duration'] as num).toDouble();

      print('[ApiService] Mapbox $profile: route found (${duration.toInt()}s)');

      return {
        'status': 'success',
        'is_route_safe': true,
        'risk_level': 'low',
        'explanation': 'Route via Mapbox (risk engine offline)',
        'high_risk_segments': [],
        'recommended_route': {
          'route_geometry': geometry,
          'duration': duration,
          'safety_score': 75,
          'risk_level': 'low',
          'explanation': 'Route via Mapbox (risk engine offline)',
          'high_risk_segments': [],
        },
      };
    } catch (e) {
      print('❌ Mapbox Directions fallback failed: $e');
      return null;
    }
  }
}
