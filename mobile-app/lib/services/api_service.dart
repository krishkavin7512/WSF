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
  final _supabase = Supabase.instance.client;

  Future<List<dynamic>> getDangerZones({int? simulatedHour}) async {
    try {
      final response = await _supabase.rpc('get_active_zones');
      return response as List<dynamic>;
    } catch (e) {
      print('❌ Zone Fetch Error: $e');
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