import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart'; //
import 'package:supabase_flutter/supabase_flutter.dart';

class ApiService {
  // Android emulator: 10.0.2.2 maps to host's localhost.
  // iOS simulator / desktop: localhost works directly.
  // Set BACKEND_API_BASE_URL in .env to override.
  final String _baseUrl = dotenv.env['BACKEND_API_BASE_URL']?.isNotEmpty == true
      ? dotenv.env['BACKEND_API_BASE_URL']!
      : 'http://10.0.2.2:8000';
  ApiService() { print('Backend URL: $_baseUrl'); }
  Future<List<dynamic>> getDangerZones({int? simulatedHour}) async {
    try {
      final hour = simulatedHour ?? DateTime.now().hour;
      final url = Uri.parse('$_baseUrl/zones?simulated_hour=$hour');
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['zones'] as List<dynamic>? ?? [];
      }
      return [];
    } catch (e) {
      print('❌ Zone Fetch Error: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getHeatmapZones({
    String? city,
    int? hour,
  }) async {
    try {
      String url = '$_baseUrl/heatmap';
      final params = <String, String>{};
      if (city != null) params['city'] = city;
      if (hour != null) params['hour'] = hour.toString();
      if (params.isNotEmpty) {
        final query = params.entries.map((e) => '${e.key}=${e.value}').join('&');
        url += '?$query';
      }
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return List<Map<String, dynamic>>.from(data['zones'] as List);
      }
      return [];
    } catch (e) {
      print('Heatmap fetch error: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>?> getSafeRoute(
      double startLat, double startLng, double endLat, double endLng) async {
    final url = Uri.parse('$_baseUrl/get-safe-route');

    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) {
        print('⚠️ Route Error: user is not authenticated.');
        return null;
      }

      final body = jsonEncode({
        "start_lat": startLat,
        "start_lng": startLng,
        "end_lat": endLat,
        "end_lng": endLng,
        "user_id": userId,
      });
      print('[ApiService] Route request URL: $url');
      print('[ApiService] Route request body: $body');

      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: body,
      );

      print('[ApiService] Route response status: ${response.statusCode}');
      print('[ApiService] Route response body: ${response.body}');

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        print('⚠️ Route Error: ${response.statusCode} — ${response.body}');
        return null;
      }
    } catch (e) {
      print('❌ Route Connection Error: $e');
      return null;
    }
  }
}