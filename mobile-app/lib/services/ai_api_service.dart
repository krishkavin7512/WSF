import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Model returned by [AiApiService.triggerDeterrent].
class DeterrentData {
  final String script;
  final String audioBase64;

  const DeterrentData({required this.script, required this.audioBase64});

  factory DeterrentData.fromJson(Map<String, dynamic> json) {
    return DeterrentData(
      script: json['script'] as String? ?? '',
      audioBase64: json['audio_base64'] as String? ?? '',
    );
  }
}

/// Isolated HTTP client for the /ai/* backend endpoints.
/// Do NOT modify api_service.dart — all new AI calls live here.
class AiApiService {
  final String _baseUrl = dotenv.env['BACKEND_API_BASE_URL']?.isNotEmpty == true
      ? dotenv.env['BACKEND_API_BASE_URL']!
      : 'http://10.0.2.2:8000';

  static const _headers = {'Content-Type': 'application/json'};

  /// POST /ai/chat
  /// Sends the user [query] along with the device's current [lat]/[lng]
  /// (from the cached location — never requests a fresh GPS fix) and the
  /// desired [language] code (e.g. "en-IN").
  /// Returns the SENTRA reply string, or null on failure.
  Future<String?> sendChatQuery({
    required String query,
    required double lat,
    required double lng,
    required String language,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/ai/chat'),
        headers: _headers,
        body: jsonEncode({
          'query': query,
          'lat': lat,
          'lng': lng,
          'language': language,
        }),
      ).timeout(const Duration(seconds: 60));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['reply'] as String?;
      }
      print('[AiApiService] /ai/chat error ${response.statusCode}: ${response.body}');
      return null;
    } catch (e) {
      print('[AiApiService] /ai/chat exception: $e');
      return null;
    }
  }

  /// POST /ai/deterrent
  /// Triggers the Sarvam Bulbul V3 audio deterrent. Uses the cached [lat]/[lng]
  /// — synchronous, never hangs waiting for a new GPS fix.
  /// Returns a [DeterrentData] containing the script and raw Base64 audio,
  /// or null on failure.
  Future<DeterrentData?> triggerDeterrent({
    required double lat,
    required double lng,
    required String language,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/ai/deterrent'),
        headers: _headers,
        body: jsonEncode({
          'lat': lat,
          'lng': lng,
          'language': language,
        }),
      ).timeout(const Duration(seconds: 60));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return DeterrentData.fromJson(data);
      }
      print('[AiApiService] /ai/deterrent error ${response.statusCode}: ${response.body}');
      return null;
    } catch (e) {
      print('[AiApiService] /ai/deterrent exception: $e');
      return null;
    }
  }
}
