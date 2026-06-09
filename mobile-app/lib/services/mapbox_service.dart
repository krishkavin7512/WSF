import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class MapboxService {
  final String _accessToken = dotenv.env['MAPBOX_ACCESS_TOKEN'] ?? '';

  /// Step 1: Returns name suggestions as the user types.
  /// Call this on every keystroke (debounced by the caller).
  Future<List<Map<String, dynamic>>> searchPlaces(
    String query, {
    double proximityLng = 78.3663,
    double proximityLat = 17.3422,
    required String sessionToken,
  }) async {
    if (query.trim().length < 2) return [];

    final url = Uri.parse(
      'https://api.mapbox.com/search/searchbox/v1/suggest'
      '?q=${Uri.encodeComponent(query)}'
      '&access_token=$_accessToken'
      '&session_token=$sessionToken'
      '&proximity=$proximityLng,$proximityLat'
      '&country=IN'
      '&language=en'
      '&limit=5'
      '&types=poi,address,place,neighborhood,locality,district',
    );

    print('[MapboxService] Suggest URL: $url');

    try {
      final response = await http.get(url);
      print('[MapboxService] Suggest status: ${response.statusCode}');
      print('[MapboxService] Suggest body: ${response.body}');

      if (response.statusCode != 200) {
        print('[MapboxService] Suggest error: ${response.statusCode} ${response.body}');
        return [];
      }

      final data = jsonDecode(response.body);
      final suggestions = data['suggestions'] as List? ?? [];
      print('[MapboxService] Suggest results count: ${suggestions.length}');

      return suggestions.map<Map<String, dynamic>>((s) => {
        'name': s['name'] ?? '',
        'place_formatted': s['place_formatted'] ?? s['full_address'] ?? '',
        'mapbox_id': s['mapbox_id'] ?? '',
      }).toList();
    } catch (e) {
      print('[MapboxService] Suggest exception: $e');
      return [];
    }
  }

  /// Step 2: Retrieves full coordinates for a selected suggestion.
  /// Must be called with the same sessionToken used in searchPlaces.
  Future<Map<String, dynamic>?> retrievePlace(
    String mapboxId, {
    required String sessionToken,
  }) async {
    print('[MapboxService] Selected mapbox_id: $mapboxId');

    final url = Uri.parse(
      'https://api.mapbox.com/search/searchbox/v1/retrieve/$mapboxId'
      '?access_token=$_accessToken'
      '&session_token=$sessionToken',
    );

    try {
      final response = await http.get(url);
      print('[MapboxService] Retrieve status: ${response.statusCode}');

      if (response.statusCode != 200) {
        print('[MapboxService] Retrieve error: ${response.statusCode} ${response.body}');
        return null;
      }

      final data = jsonDecode(response.body);
      final features = data['features'] as List? ?? [];
      if (features.isEmpty) return null;

      final coords = features[0]['geometry']['coordinates'];
      final props = features[0]['properties'];

      final double lng = (coords[0] as num).toDouble();
      final double lat = (coords[1] as num).toDouble();
      print('[MapboxService] Retrieved coords: $lat, $lng');

      return {
        'lng': lng,
        'lat': lat,
        'name': props['name'] ?? '',
        'full_address': props['full_address'] ?? props['place_formatted'] ?? '',
      };
    } catch (e) {
      print('[MapboxService] Retrieve exception: $e');
      return null;
    }
  }
}
