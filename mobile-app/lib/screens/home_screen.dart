import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
// 1. HIDE 'Size' from Mapbox to avoid conflict with Flutter's Size
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import 'package:permission_handler/permission_handler.dart';
import 'package:sliding_up_panel/sliding_up_panel.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_app/theme/sentra_design.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:mobile_app/services/api_service.dart';
import 'package:mobile_app/services/mapbox_service.dart';
import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile_app/services/audio_sentinel_service.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:mobile_app/services/geofence_service.dart';
import 'package:mobile_app/services/location_service.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io' show Platform;


class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  static const EventChannel _volumeButtonChannel =
      EventChannel('wsf/hardware_buttons');
  MapboxMap? mapboxMap;
  PolygonAnnotationManager? _polygonManager;
  PolylineAnnotationManager? _polylineManager;
  PointAnnotationManager? _pointManager;

  final ApiService _apiService = ApiService();
  final MapboxService _mapboxService = MapboxService();

  // Audio Sentinel Service
  final AudioSentinelService _audioSentinel = AudioSentinelService();

  // Text Controllers
  final TextEditingController _startController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();

  // Focus Nodes
  final FocusNode _startFocus = FocusNode();
  final FocusNode _destinationFocus = FocusNode();
  Timer? _debounce;

  // Coordinates
  // _cameraLat/_cameraLng are ONLY used for the initial MapWidget cameraOptions.
  // They are intentionally never updated so that setState calls from location
  // updates do not cause MapWidget to reapply cameraOptions and jump the camera.
  static const double _cameraLat = 17.3422;
  static const double _cameraLng = 78.3663;

  double _startLat = 17.3422; // Lords default — updated by real GPS
  double _startLng = 78.3663;
  double? _destLat;
  double? _destLng;

  // Set true once the camera has auto-centered on the first valid GPS fix, so
  // we center exactly once and never fight the user panning the map afterwards.
  bool _hasCenteredOnUser = false;

  // Search Box API state
  List<Map<String, dynamic>> _suggestions = [];
  String _searchSessionToken = '';
  bool _isSearchLoading = false;

  // Destination preview state (pin placed, waiting for user to confirm route)
  bool _isPendingRoute = false;
  String _pendingDestName = '';
  Map<String, dynamic>? _pendingRouteData; // cached route result shown during preview
  bool _isRouteFetching = false; // guard: prevent concurrent _fetchAndDrawRoute calls
  DateTime? _lastAudioIncidentAt;   // cooldown: one incident per 30 s maximum
  String?   _activeAudioIncidentId; // id of the open audio incident (cleared on resolve)
  bool      _audioAlertShowing = false; // guard: prevent stacked overlays

  // State Variables
  bool _isRouteActive = false;
  bool _isTracking = false;
  bool _isInputExpanded = false;
  bool _isNightMode = false;
  bool _isRouteSafe = true;
  int _riskScore = 0;
  double _durationMin = 0;

  // Multi-factor risk engine fields
  String _riskLevel = 'low';       // 'low' | 'medium' | 'high'
  String _riskExplanation = '';
  int _highRiskSegmentCount = 0;

  List<Position> _currentRouteGeometry = [];
  String? _activeTripId;
  StreamSubscription? _volumeDownSubscription;
  final List<DateTime> _volumeDownPresses = [];
  bool _isImmediateSosDispatching = false;

  // ✅ NEW: Zone Logic Variables
  List<dynamic> _activeZones = [];
  List<Map<String, dynamic>> _safeHavens = [];

  // Heatmap
  bool _showHeatmap = false;
  List<Map<String, dynamic>> _heatmapZones = [];
  PolygonAnnotationManager? _heatmapManager; // Stores current zones for calculation
  String _safetyStatusTitle = "SENTRA ACTIVE";
  String _safetyStatusSubtitle = "You are in a Safe Zone";
  Color _safetyPanelBg = SentraDesign.uberBlack;
  Color _safetyPrimaryText = SentraDesign.pureWhite;
  Color _safetySecondaryText = const Color(0xB3FFFFFF);
  Color _safetyIconColor = SentraDesign.pureWhite;
  IconData _safetyIcon = Icons.shield_moon;

  int _navIndex = 0;

  @override
  void initState() {
    super.initState();
    _startController.text = "Current Location";
    _initAudioSentinel();
    _initVolumeDownOverride();
    _ensureProfile(); // upsert profile row so display is always fresh for this user
    _requestPermissions().then((_) => _initBackgroundTracking());
  }

  @override
  void dispose() {
    if (_activeTripId != null) {
      Supabase.instance.client
          .from('trips')
          .update({
            'status': 'completed',
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', _activeTripId!)
          .catchError((_) {});
    }
    _startController.dispose();
    _destinationController.dispose();
    _startFocus.dispose();
    _destinationFocus.dispose();
    _debounce?.cancel();
    _volumeDownSubscription?.cancel();
    _audioSentinel.stopListening();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.location,
      Permission.microphone,
    ].request();
  }

  /// Upserts the profiles row from live auth metadata every time HomeScreen mounts.
  /// Ensures the display name/phone is always current for the logged-in user,
  /// and creates the row for users who signed up before the auth trigger existed.
  Future<void> _ensureProfile() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    final metaName = user.userMetadata?['full_name'] as String?;
    await Supabase.instance.client.from('profiles').upsert({
      'id': user.id,
      'full_name': metaName,
      'phone': user.phone,
    }, onConflict: 'id').catchError((_) {});
  }

  void _initAudioSentinel() async {
    await _audioSentinel.initialize();
    _audioSentinel.onDangerDetected = (event, confidence) async {
      print('=== AUDIO DANGER DETECTED ===');
      print('Label: $event');
      print('Confidence: $confidence');

      // Write incident to Supabase — once per 30 s max (sustained sounds re-trigger).
      final now = DateTime.now();
      final bool cooledDown = _lastAudioIncidentAt == null ||
          now.difference(_lastAudioIncidentAt!) > const Duration(seconds: 30);

      final supabase = Supabase.instance.client;
      final userId = supabase.auth.currentUser?.id;

      if (cooledDown && userId != null) {
        _lastAudioIncidentAt = now;
        print('[AudioSentinel] Writing incident to Supabase...');
        try {
          final insertResult = await supabase.from('incidents').insert({
            'user_id':      userId,
            'source':       'audio',
            'severity':     3,
            'status':       'open',
            'latitude':     _startLat,
            'longitude':    _startLng,
            'notes':        'Audio threat detected: $event (${(confidence * 100).toStringAsFixed(0)}% confidence)',
            'display_name': supabase.auth.currentUser?.userMetadata?['full_name'] ?? 'SENTRA user',
          }).select('id').single();
          _activeAudioIncidentId = insertResult['id'] as String?;
          print('[AudioSentinel] Incident written OK (id: $_activeAudioIncidentId)');
        } catch (e) {
          print('[AudioSentinel] ❌ Incident write FAILED: $e');
        }
        // Show overlay only after a confirmed insert, and never stack them.
        if (mounted && ModalRoute.of(context)?.isCurrent == true && !_audioAlertShowing) {
          _showAudioAlert(event, confidence);
        }
      } else if (userId == null) {
        print('[AudioSentinel] ⚠️ No authenticated user — incident not written');
      } else {
        print('[AudioSentinel] Cooldown active — skipping duplicate');
      }
    };
    _audioSentinel.startListening();
    setState(() {});
  }

  void _showAudioAlert(String label, double confidence) async {
    _audioAlertShowing = true;
    final bool isSafe = await showGeneralDialog<bool>(
          context: context,
          barrierDismissible: false,
          barrierColor: const Color(0xF0CC0000),
          transitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (ctx, anim1, anim2) =>
              AudioThreatOverlay(label: label, confidence: confidence),
        ) ??
        false;
    _audioAlertShowing = false;

    if (isSafe) {
      // User confirmed they're safe — resolve the incident so dashboard clears it.
      final incidentId = _activeAudioIncidentId;
      if (incidentId != null) {
        try {
          await Supabase.instance.client.from('incidents').update({
            'status':      'resolved',
            'resolved_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', incidentId);
          print('[AudioSentinel] Incident $incidentId resolved');
        } catch (e) {
          print('[AudioSentinel] ❌ Resolve failed: $e');
        }
        if (mounted) setState(() => _activeAudioIncidentId = null);
      }
    } else {
      _handleSosSequence(
        triggerReason: 'Audio threat detected: ${label.toUpperCase()}',
      );
    }
  }

  void _initVolumeDownOverride() {
    if (!Platform.isAndroid) return;
    try {
      _volumeDownSubscription =
          _volumeButtonChannel.receiveBroadcastStream().listen(
        (_) => _onVolumeDownPressed(),
        onError: (error) {
          print('Volume button listener error: $error');
        },
      );
    } catch (e) {
      print('Hardware buttons error: $e');
    }
  }

  void _onVolumeDownPressed() {
    final now = DateTime.now();
    _volumeDownPresses.add(now);
    _volumeDownPresses.removeWhere(
      (pressedAt) => now.difference(pressedAt) > const Duration(seconds: 2),
    );

    if (_volumeDownPresses.length >= 3) {
      _volumeDownPresses.clear();
      _triggerImmediateSosBypass();
    }
  }

  // ✅ NEW: Geofence OS Tracking Engine
  void _initBackgroundTracking() async {
    final geofenceService = GeofenceService();

    geofenceService.onDangerZoneTrigger = (bg.GeofenceEvent event) {
      if (mounted) {
        setState(() {
          if (event.action == "ENTER") {
            String severity =
                event.extras != null && event.extras!['risk_level'] != null
                    ? event.extras!['risk_level']
                    : "red";

            if (severity == "yellow" || severity == "MODERATE") {
              _safetyStatusTitle = "CAUTION ADVISED";
              _safetyStatusSubtitle = "Entered Moderate Risk Zone";
              _safetyPanelBg = SentraDesign.chipGray;
              _safetyPrimaryText = SentraDesign.uberBlack;
              _safetySecondaryText = SentraDesign.bodyGray;
              _safetyIconColor = SentraDesign.uberBlack;
              _safetyIcon = Icons.warning_amber_rounded;
            } else {
              _safetyStatusTitle = "DANGER DETECTED";
              _safetyStatusSubtitle = "You are in a High Risk Zone!";
              _safetyPanelBg = SentraDesign.uberBlack;
              _safetyPrimaryText = SentraDesign.pureWhite;
              _safetySecondaryText = const Color(0xB3FFFFFF);
              _safetyIconColor = SentraDesign.pureWhite;
              _safetyIcon = Icons.report_problem_rounded;
            }
          } else if (event.action == "EXIT") {
            _safetyStatusTitle = "SENTRA ACTIVE";
            _safetyStatusSubtitle = "You are in a Safe Zone";
            _safetyPanelBg = SentraDesign.uberBlack;
            _safetyPrimaryText = SentraDesign.pureWhite;
            _safetySecondaryText = const Color(0xB3FFFFFF);
            _safetyIconColor = SentraDesign.pureWhite;
            _safetyIcon = Icons.shield_moon;
          }
        });
      }
    };

    geofenceService.onDriftAlert = () {
      if (mounted) {
        _showDriftOverlay();
      }
    };

    // LocationService is the SINGLE filtered source of position. It is the only
    // code path allowed to set _startLat/_startLng from GPS. Fixes arriving here
    // have already passed the accuracy (≤100 m) and jump (≤50 km) gates.
    LocationService().onLocationUpdate = (lat, lng, heading, speed) {
      if (!mounted) return;
      final bool isFirstFix = !_hasCenteredOnUser;
      setState(() {
        _startLat = lat;
        _startLng = lng;
      });
      // Center the camera exactly once, on the first valid fix.
      if (isFirstFix) {
        _hasCenteredOnUser = true;
        mapboxMap?.flyTo(
          CameraOptions(
            center: Point(coordinates: Position(lng, lat)),
            zoom: 15.0,
          ),
          MapAnimationOptions(duration: 1000),
        );
      }
    };

    // Order matters: LocationService.initialize() calls ready()/start() on the
    // plugin, which must happen before GeofenceService adds geofences.
    await LocationService().initialize();
    await geofenceService.initialize();
    _loadSafeHavens();
  }

  _onMapCreated(MapboxMap mapboxMap) {
    this.mapboxMap = mapboxMap;

    // Disable scale bar and move all ornaments to bottom-left
    mapboxMap.scaleBar.updateSettings(ScaleBarSettings(enabled: false));
    mapboxMap.compass.updateSettings(CompassSettings(
      position: OrnamentPosition.BOTTOM_LEFT,
      marginBottom: 80,
      marginLeft: 8,
    ));
    mapboxMap.attribution.updateSettings(AttributionSettings(
      position: OrnamentPosition.BOTTOM_LEFT,
      marginBottom: 8,
      marginLeft: 8,
    ));
    mapboxMap.logo.updateSettings(LogoSettings(
      position: OrnamentPosition.BOTTOM_LEFT,
      marginBottom: 8,
      marginLeft: 96,
    ));

    // ✅ NEW: Enable the Blue Dot (Location Component)
    mapboxMap.location.updateSettings(
      LocationComponentSettings(
        enabled: true,
        pulsingEnabled: true,
        pulsingColor: Colors.blueAccent.value,
        pulsingMaxRadius: 30.0,
      ),
    );

    // Initialize Annotation Managers
    mapboxMap.annotations.createPolygonAnnotationManager().then((manager) {
      _polygonManager = manager;
      _loadDangerZones();
    });
    mapboxMap.annotations.createPolylineAnnotationManager().then((manager) {
      _polylineManager = manager;
    });
    mapboxMap.annotations.createPointAnnotationManager().then((manager) {
      _pointManager = manager;
    });
    mapboxMap.annotations.createPolygonAnnotationManager().then((manager) {
      _heatmapManager = manager;
      final hour = DateTime.now().hour;
      if (hour >= 20 || hour < 7) {
        setState(() => _showHeatmap = true);
        _loadHeatmap();
      }
    });
  }

  // --- DANGER ZONES ---
  Future<void> _loadDangerZones() async {
    // Only use simulated time if you add temporal logic to get_active_zones
    int simulatedTime = _isNightMode ? 22 : 10;
    await _polygonManager?.deleteAll();

    final zones = await _apiService.getDangerZones(
      simulatedHour: simulatedTime,
    );

    // ✅ NEW: Store raw zones for OS Geofencing
    _activeZones = zones;
    GeofenceService().setupPolygons(_activeZones);

    if (zones.isEmpty) return;

    List<PolygonAnnotationOptions> polygonOptions = [];
    for (var zone in zones) {
      if (zone['boundary'] != null) {
        String severity = zone['risk_level'] ?? 'red';

        // Render Red Zones with 40% Opacity
        int activeFillColor = severity == 'yellow'
            ? Colors.amber.withOpacity(0.40).value
            : Colors.red.withOpacity(0.40).value;
        int activeStrokeColor = severity == 'yellow'
            ? Colors.amber.withOpacity(0.8).value
            : Colors.red.withOpacity(0.8).value;

        final rawBoundary = zone['boundary'];
        final boundary = rawBoundary is String
            ? jsonDecode(rawBoundary) as Map<String, dynamic>
            : rawBoundary as Map<String, dynamic>;

        if (boundary['type'] == 'Polygon') {
          List<dynamic> ringData = boundary['coordinates'][0];
          List<Position> geomPoints = ringData.map((pt) {
            return Position(pt[0].toDouble(), pt[1].toDouble());
          }).toList();

          polygonOptions.add(
            PolygonAnnotationOptions(
              geometry: Polygon(coordinates: [geomPoints]),
              fillColor: activeFillColor,
              fillOutlineColor: activeStrokeColor,
            ),
          );
        } else if (boundary['type'] == 'MultiPolygon') {
          List<dynamic> polygons = boundary['coordinates'];
          for (var poly in polygons) {
            List<dynamic> ringData = poly[0];
            List<Position> geomPoints = ringData.map((pt) {
              return Position(pt[0].toDouble(), pt[1].toDouble());
            }).toList();

            polygonOptions.add(PolygonAnnotationOptions(
              geometry: Polygon(coordinates: [geomPoints]),
              fillColor: activeFillColor,
              fillOutlineColor: activeStrokeColor,
            ));
          }
        }
      }
    }
    await _polygonManager?.createMulti(polygonOptions);
  }

  // --- SOS LOGIC ---
  void _showDriftOverlay({String? dangerReason}) async {
    bool isSafe = await showGeneralDialog<bool>(
          context: context,
          barrierDismissible: false,
          barrierColor: Colors.black.withOpacity(0.95),
          transitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (context, anim1, anim2) {
            return DriftSosOverlay(dangerReason: dangerReason);
          },
        ) ??
        false;

    if (!isSafe && _activeTripId != null) {
      // User didn't answer within 15 seconds!
      try {
        await Supabase.instance.client
            .from('trips')
            .update({'status': 'sos'}).eq('id', _activeTripId as String);
      } catch (e) {
        print("Failed to dispatch SOS to Db: $e");
      }
      _handleSosSequence(
          triggerReason: dangerReason ?? "No response after straying from expected route.");
    }
  }

  void _handleSosSequence({String? triggerReason}) async {
    bool shouldSend = await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) =>
              SosCountdownDialog(triggerReason: triggerReason),
        ) ??
        false;

    if (shouldSend) {
      _launchSmsApp();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("SOS Cancelled"),
        ),
      );
    }
  }

  Future<void> _launchSmsApp() async {
    const String emergencyNumber = "+919940903891";
    // ✅ Updated to send actual coordinates if available
    final String message =
        "SOS! I need help. My current location is: https://maps.google.com/?q=$_startLat,$_startLng";

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Opening SMS App..."),
        duration: Duration(seconds: 2),
      ),
    );

    final Uri smsUri = Uri(
      scheme: 'sms',
      path: emergencyNumber,
      queryParameters: <String, String>{'body': message},
    );
    if (await canLaunchUrl(smsUri)) {
      await launchUrl(smsUri);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Could not launch SMS app."),
        ),
      );
    }
  }

  Future<void> _triggerImmediateSosBypass() async {
    if (_isImmediateSosDispatching) return;
    _isImmediateSosDispatching = true;

    GeofenceService().cancelDriftTimer();
    SosCountdownDialog.dismissIfActive();
    DriftSosOverlay.dismissIfActive();

    try {
      if (_activeTripId != null) {
        await Supabase.instance.client
            .from('trips')
            .update({'status': 'sos'}).eq('id', _activeTripId as String);
      } else {
        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId != null) {
          await Supabase.instance.client
              .from('trips')
              .update({'status': 'sos'})
              .eq('user_id', userId)
              .eq('status', 'active');
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Emergency override activated. Security dispatched."),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to dispatch emergency: $e")),
      );
    } finally {
      _isImmediateSosDispatching = false;
    }
  }

  // --- ROUTE LOGIC ---
  void _handleMapTap(MapContentGestureContext context) {
    final point = context.point;
    final double lat = point.coordinates.lat.toDouble();
    final double lng = point.coordinates.lng.toDouble();

    setState(() {
      _isInputExpanded = true;
      _destLat = lat;
      _destLng = lng;
      _destinationController.text =
          "${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}";
    });

    _fetchAndDrawRoute(lat, lng);
  }

  void _onSearchChanged(String query, bool isStart) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    if (query.isEmpty) {
      setState(() {
        _suggestions = [];
        _isSearchLoading = false;
      });
      return;
    }

    // Mint a new session token on the first keystroke of each search session.
    if (_searchSessionToken.isEmpty) {
      _searchSessionToken = 'session_${DateTime.now().millisecondsSinceEpoch}';
    }

    setState(() => _isSearchLoading = true);

    _debounce = Timer(const Duration(milliseconds: 400), () async {
      if (query.trim().length < 2) {
        if (mounted) {
          setState(() {
            _suggestions = [];
            _isSearchLoading = false;
          });
        }
        return;
      }
      final results = await _mapboxService.searchPlaces(
        query,
        sessionToken: _searchSessionToken,
      );
      print(
          '[HomeScreen] Results count: ${results.length} for query: "$query"');
      if (mounted) {
        setState(() {
          _suggestions = results;
          _isSearchLoading = false;
        });
      }
    });
  }

  Future<void> _selectSuggestion(
      Map<String, dynamic> suggestion, bool isStart) async {
    final String mapboxId = suggestion['mapbox_id'] ?? '';
    final String displayName = suggestion['name'] ?? '';

    _startFocus.unfocus();
    _destinationFocus.unfocus();
    setState(() {
      _suggestions = [];
      _isSearchLoading = true;
      _isInputExpanded = false;
    });

    final place = await _mapboxService.retrievePlace(
      mapboxId,
      sessionToken: _searchSessionToken,
    );

    _searchSessionToken = '';

    if (!mounted) return;
    setState(() => _isSearchLoading = false);

    if (place == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Could not get location details. Try again.")),
      );
      return;
    }

    final double lat = place['lat'] as double;
    final double lng = place['lng'] as double;
    final String name = (place['name'] as String).isNotEmpty
        ? place['name'] as String
        : displayName;

    if (isStart) {
      setState(() {
        _startLat = lat;
        _startLng = lng;
        _startController.text = name;
      });
      return;
    }

    // Destination selected — place a red pin and fly camera before routing
    setState(() {
      _destLat = lat;
      _destLng = lng;
      _destinationController.text = name;
      _isPendingRoute = true;
      _pendingDestName = name;
    });

    // Drop destination pin (red-tinted)
    await _pointManager?.deleteAll();
    await _pointManager?.create(
      PointAnnotationOptions(
        geometry: Point(coordinates: Position(lng, lat)),
        iconImage: "marker-15",
        iconSize: 2.5,
        iconColor: Colors.redAccent.value,
      ),
    );

    // Fetch the real road-following route immediately so it's visible in preview
    await _fetchAndDrawRoute(lat, lng, isPreview: true);
  }

  Future<void> _fetchAndDrawRoute(double endLat, double endLng, {bool isPreview = false}) async {
    if (_isRouteFetching) {
      print('[Route] Skipping — fetch already in progress');
      return;
    }
    setState(() => _isRouteFetching = true);

    print('[Route] Origin: $_startLat, $_startLng');
    print('[Route] Destination: $endLat, $endLng');

    try {
    if (!mounted) return;  // finally still runs — _isRouteFetching cleared
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Calculating safest path..."),
        duration: Duration(seconds: 1),
      ),
    );
    await _polylineManager?.deleteAll();
    await _pointManager?.deleteAll();

    final result = await _apiService.getSafeRoute(
      _startLat,
      _startLng,
      endLat,
      endLng,
    );

    if (!mounted) return;

    if (result != null && result['status'] == 'success') {
      final route = result['recommended_route'];
      final String encodedPolyline = route['route_geometry'];
      final int safetyScore = (route['safety_score'] as num?)?.toInt() ?? 50;
      final double duration = (route['duration'] as num) / 60;
      final bool routeSafe = result['is_route_safe'] ?? true;

      // Multi-factor risk fields (new engine)
      final String riskLevel = result['risk_level'] as String? ?? route['risk_level'] as String? ?? 'low';
      final String explanation = result['explanation'] as String? ?? route['explanation'] as String? ?? '';
      final List highRiskSegs = result['high_risk_segments'] as List? ?? route['high_risk_segments'] as List? ?? [];

      PolylinePoints polylinePoints = PolylinePoints();
      List<PointLatLng> decodedPoints = polylinePoints.decodePolyline(encodedPolyline);
      List<Position> routeGeometry =
          decodedPoints.map((p) => Position(p.longitude, p.latitude)).toList();

      // Route color based on multi-factor risk level
      Color routeColor;
      if (riskLevel == 'high') {
        routeColor = const Color(0xFFFF3B30);
      } else if (riskLevel == 'medium') {
        routeColor = Colors.orange;
      } else {
        routeColor = Colors.green;
      }

      _polylineManager?.create(
        PolylineAnnotationOptions(
          geometry: LineString(coordinates: routeGeometry),
          lineColor: routeColor.value,
          lineWidth: 4.0,
          lineJoin: LineJoin.ROUND,
        ),
      );

      _pointManager?.create(
        PointAnnotationOptions(
          geometry: Point(coordinates: Position(endLng, endLat)),
          iconImage: "marker-15",
          iconSize: 1.5,
        ),
      );

      if (isPreview) {
        setState(() {
          _pendingRouteData = result;
          _currentRouteGeometry = routeGeometry;
          _isRouteSafe = routeSafe;
          _riskScore = 100 - safetyScore;
          _durationMin = duration;
          _riskLevel = riskLevel;
          _riskExplanation = explanation;
          _highRiskSegmentCount = highRiskSegs.length;
        });
      } else {
        setState(() {
          _isRouteActive = true;
          _isTracking = false;
          _isRouteSafe = routeSafe;
          _riskScore = 100 - safetyScore;
          _durationMin = duration;
          _currentRouteGeometry = routeGeometry;
          _riskLevel = riskLevel;
          _riskExplanation = explanation;
          _highRiskSegmentCount = highRiskSegs.length;
        });
      }

      // Fly camera to show the full route
      if (mapboxMap != null && routeGeometry.isNotEmpty) {
        final lngs = routeGeometry.map((p) => p.lng.toDouble());
        final lats = routeGeometry.map((p) => p.lat.toDouble());
        final minLng = lngs.reduce((a, b) => a < b ? a : b);
        final maxLng = lngs.reduce((a, b) => a > b ? a : b);
        final minLat = lats.reduce((a, b) => a < b ? a : b);
        final maxLat = lats.reduce((a, b) => a > b ? a : b);
        try {
          final camera = await mapboxMap!.cameraForCoordinateBounds(
            CoordinateBounds(
              southwest: Point(coordinates: Position(minLng - 0.005, minLat - 0.005)),
              northeast: Point(coordinates: Position(maxLng + 0.005, maxLat + 0.005)),
              infiniteBounds: false,
            ),
            MbxEdgeInsets(top: 80, left: 60, bottom: 160, right: 60),
            null, null, null, null,
          );
          await mapboxMap!.flyTo(camera, MapAnimationOptions(duration: 1000));
        } catch (_) {}
      }
    } else if (result != null && result['status'] == 'error') {
      final msg = result['message'] as String? ?? 'Routing failed';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Unable to calculate route: $msg")),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Unable to calculate route. Please try a different destination."),
        ),
      );
    }
    } finally {
      if (mounted) setState(() => _isRouteFetching = false);
    }
  }

  void _toggleSimulationMode() {
    setState(() {
      _isNightMode = !_isNightMode;
      // Reset to safe default until new zones load
      if (!_activeZones.any((z) => z['severity'] != null)) {
        _safetyPanelBg = SentraDesign.uberBlack;
        _safetyPrimaryText = SentraDesign.pureWhite;
        _safetySecondaryText = const Color(0xB3FFFFFF);
        _safetyIconColor = SentraDesign.pureWhite;
      }
    });

    if (mapboxMap != null) {
      mapboxMap!.loadStyleURI(
        _isNightMode ? MapboxStyles.DARK : MapboxStyles.MAPBOX_STREETS,
      );
      Future.delayed(const Duration(milliseconds: 300), () {
        _loadDangerZones();
      });
    }
  }

  Future<void> _loadSafeHavens() async {
    final token = dotenv.env['MAPBOX_ACCESS_TOKEN'] ?? '';
    if (token.isEmpty) return;

    const categories = ['police', 'hospital', 'pharmacy', 'fire_station'];
    final List<Map<String, dynamic>> results = [];

    for (final category in categories) {
      try {
        final url = Uri.parse(
          'https://api.mapbox.com/search/searchbox/v1/category/$category'
          '?access_token=$token'
          '&proximity=$_startLng,$_startLat'
          '&limit=2'
          '&language=en',
        );
        final response = await http.get(url);
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final features = data['features'] as List? ?? [];
          for (final f in features) {
            final coords = f['geometry']['coordinates'] as List;
            final props = f['properties'] as Map<String, dynamic>;
            final dist = _calculateDistance(
              _startLat, _startLng,
              coords[1].toDouble(), coords[0].toDouble(),
            );
            results.add({
              'name': props['name'] ?? category,
              'category': category,
              'distance': dist,
              'lat': coords[1].toDouble(),
              'lng': coords[0].toDouble(),
              'address': props['full_address'] ?? props['place_formatted'] ?? '',
            });
          }
        }
      } catch (e) {
        print('[SafeHavens] Failed to fetch $category: $e');
      }
    }

    results.sort((a, b) =>
        (a['distance'] as double).compareTo(b['distance'] as double));

    if (mounted) {
      setState(() {
        _safeHavens = results.take(4).toList();
      });
    }
  }

  double _calculateDistance(
      double lat1, double lng1, double lat2, double lng2) {
    const R = 6371.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLng / 2) *
            sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  void _selectDestinationFromSafeHaven(
      double lat, double lng, String name) {
    _pointManager?.deleteAll();
    _polylineManager?.deleteAll();
    setState(() {
      _destLat = lat;
      _destLng = lng;
      _destinationController.text = name;
      _isPendingRoute = true;
      _pendingDestName = name;
    });
    _fetchAndDrawRoute(lat, lng, isPreview: true);
  }

  // --- HEATMAP ---

  Future<void> _loadHeatmap() async {
    String city = 'hyderabad';
    if (_startLat >= 12.8 && _startLat <= 13.3 &&
        _startLng >= 80.0 && _startLng <= 80.4) {
      city = 'chennai';
    }
    print('Current location: $_startLat, $_startLng');
    print('Detected city: $city');
    final zones = await _apiService.getHeatmapZones(
      city: city,
      hour: DateTime.now().hour,
      showAll: true,
    );
    setState(() => _heatmapZones = zones);
    await _renderHeatmap();
  }

  Future<void> _renderHeatmap() async {
    print('CircleAnnotationManager (polygon): $_heatmapManager');
    print('Rendering ${_heatmapZones.length} heatmap zones');
    if (_heatmapManager == null) {
      print('ERROR: _heatmapManager is null — skipping render');
      return;
    }
    await _heatmapManager!.deleteAll();
    final List<PolygonAnnotationOptions> options = [];
    for (final zone in _heatmapZones) {
      // Backend may return center_lat/center_lng OR latitude/longitude depending
      // on how the heatmap_zones table columns are named.
      final double lat = ((zone['latitude'] ?? zone['center_lat']) as num).toDouble();
      final double lng = ((zone['longitude'] ?? zone['center_lng']) as num).toDouble();
      final double radiusM = (zone['radius_m'] as num).toDouble();
      print('  zone: lat=$lat lng=$lng radius=${radiusM}m level=${zone['risk_level']}');
      final String level = zone['risk_level'] as String? ?? 'medium';
      final int fillColor = level == 'high'
          ? Colors.red.withValues(alpha: 0.25).toARGB32()
          : Colors.orange.withValues(alpha: 0.20).toARGB32();
      final int strokeColor = level == 'high'
          ? Colors.red.withValues(alpha: 0.55).toARGB32()
          : Colors.orange.withValues(alpha: 0.50).toARGB32();
      final ring = _generateCirclePolygon(lat, lng, radiusM);
      options.add(PolygonAnnotationOptions(
        geometry: Polygon(coordinates: [ring]),
        fillColor: fillColor,
        fillOutlineColor: strokeColor,
      ));
    }
    if (options.isNotEmpty) {
      await _heatmapManager!.createMulti(options);
    }
  }

  Future<void> _clearHeatmap() async {
    await _heatmapManager?.deleteAll();
    setState(() => _heatmapZones = []);
  }

  List<Position> _generateCirclePolygon(
      double lat, double lng, double radiusM,
      {int points = 32}) {
    const double earthRadius = 6371000.0;
    final List<Position> coords = [];
    for (int i = 0; i <= points; i++) {
      final double angle = (i / points) * 2 * pi;
      final double dLat =
          (radiusM / earthRadius) * (180 / pi) * sin(angle);
      final double dLng = (radiusM / earthRadius) *
          (180 / pi) *
          cos(angle) /
          cos(lat * pi / 180);
      coords.add(Position(lng + dLng, lat + dLat));
    }
    return coords;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SlidingUpPanel(
        maxHeight: _isPendingRoute ? 0 : 450,
        minHeight: _isPendingRoute ? 0 : 180,
        parallaxEnabled: !_isPendingRoute,
        parallaxOffset: .5,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24.0),
          topRight: Radius.circular(24.0),
        ),
        panel: _isPendingRoute ? const SizedBox.shrink() : _buildBottomSheet(),
        body: Stack(
          children: [
            MapWidget(
              key: const ValueKey("mapWidget"),
              cameraOptions: CameraOptions(
                center: Point(coordinates: Position(_cameraLng, _cameraLat)),
                zoom: 15.0,
              ),
              styleUri: _isNightMode
                  ? MapboxStyles.DARK
                  : MapboxStyles.MAPBOX_STREETS,
              onMapCreated: _onMapCreated,
              onTapListener: _handleMapTap,
            ),
            _buildAnimatedSearchPanel(),
            if (_isPendingRoute) _buildDestinationPreviewCard(),
            Positioned(
              top: 120,
              right: 12,
              child: SafeArea(
                child: FloatingActionButton.small(
                  heroTag: 'heatmap_toggle',
                  backgroundColor:
                      _showHeatmap ? Colors.red.shade700 : Colors.grey.shade800,
                  onPressed: () {
                    setState(() => _showHeatmap = !_showHeatmap);
                    if (_showHeatmap) {
                      _loadHeatmap();
                    } else {
                      _clearHeatmap();
                    }
                  },
                  child: const Icon(
                    Icons.layers,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _buildNavBar(),
    );
  }

  Widget _buildAnimatedSearchPanel() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: GestureDetector(
          onTap: () {
            if (!_isInputExpanded) setState(() => _isInputExpanded = true);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            height: _isInputExpanded
                ? 160 +
                    (_isSearchLoading ? 48 : 0) +
                    (_suggestions.length * 64).toDouble()
                : 52,
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: _isInputExpanded
                  ? const BorderRadius.only(
                      bottomLeft: Radius.circular(20),
                      bottomRight: Radius.circular(20),
                    )
                  : BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: _isInputExpanded
                    ? _buildExpandedInputs()
                    : _buildCollapsedInput(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsedInput() {
    return Padding(
      key: const ValueKey("collapsed"),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(Icons.search, color: Colors.grey.shade400, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "Where to?",
              style: GoogleFonts.inter(
                color: Colors.grey.shade400,
                fontWeight: FontWeight.w500,
                fontSize: 16,
              ),
            ),
          ),
          Icon(Icons.mic, color: Colors.grey.shade400, size: 22),
        ],
      ),
    );
  }

  Widget _buildExpandedInputs() {
    const fieldBg = Color(0xFF2C2C2C);
    final hintStyle = GoogleFonts.inter(color: Colors.grey.shade400, fontSize: 15);
    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(28),
      borderSide: BorderSide.none,
    );
    final focusedBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(28),
      borderSide: const BorderSide(color: Color(0xFF00BCD4), width: 1.5),
    );

    return Padding(
      key: const ValueKey("expanded"),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Back arrow + origin field
          Row(
            children: [
              GestureDetector(
                onTap: () {
                  setState(() {
                    _isInputExpanded = false;
                    _suggestions = [];
                    _isSearchLoading = false;
                    _searchSessionToken = '';
                  });
                  _startFocus.unfocus();
                  _destinationFocus.unfocus();
                },
                child: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: TextField(
                    controller: _startController,
                    focusNode: _startFocus,
                    onChanged: (val) => _onSearchChanged(val, true),
                    cursorColor: const Color(0xFF00BCD4),
                    style: GoogleFonts.inter(color: Colors.white, fontSize: 15),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: fieldBg,
                      hintText: "Current Location",
                      hintStyle: hintStyle,
                      prefixIcon: const Padding(
                        padding: EdgeInsets.only(left: 14, right: 10),
                        child: Center(
                          widthFactor: 0,
                          child: SizedBox(
                            width: 10,
                            height: 10,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                      prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      border: fieldBorder,
                      enabledBorder: fieldBorder,
                      focusedBorder: focusedBorder,
                    ),
                  ),
                ),
              ),
            ],
          ),

          // Connector line — left-aligned under the dot icon
          Padding(
            padding: const EdgeInsets.only(left: 46),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 1.5,
                height: 16,
                color: Colors.grey.shade600,
              ),
            ),
          ),

          // Destination field + map icon
          Row(
            children: [
              const SizedBox(width: 34),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: TextField(
                    controller: _destinationController,
                    focusNode: _destinationFocus,
                    onChanged: (val) => _onSearchChanged(val, false),
                    autofocus: true,
                    cursorColor: const Color(0xFF00BCD4),
                    style: GoogleFonts.inter(color: Colors.white, fontSize: 15).copyWith(overflow: TextOverflow.ellipsis),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: fieldBg,
                      hintText: "Where to?",
                      hintStyle: hintStyle,
                      prefixIcon: const Icon(Icons.location_on,
                          color: Colors.red, size: 20),
                      suffixIcon: GestureDetector(
                        onTap: () {
                          setState(() => _isInputExpanded = false);
                          _startFocus.unfocus();
                          _destinationFocus.unfocus();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text("Tap on the map to select destination"),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                        child: Icon(Icons.map_outlined,
                            color: Colors.grey.shade500, size: 22),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      border: fieldBorder,
                      enabledBorder: fieldBorder,
                      focusedBorder: focusedBorder,
                    ),
                  ),
                ),
              ),
            ],
          ),

          if (_isSearchLoading || _suggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(height: 1, color: const Color(0xFF333333)),
            _buildSuggestionsList(),
          ],
        ],
      ),
    );
  }

  Widget _buildSuggestionsList() {
    if (_isSearchLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_suggestions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Text(
          "No results found near Hyderabad",
          style: GoogleFonts.inter(fontSize: 12, color: SentraDesign.mutedGray),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: _suggestions.map((suggestion) {
        final String name = suggestion['name'] ?? '';
        final String subtitle = suggestion['place_formatted'] ?? '';
        return InkWell(
          onTap: () {
            final bool isStart = _startFocus.hasFocus;
            _selectSuggestion(suggestion, isStart);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              children: [
                const Icon(Icons.location_on_outlined,
                    size: 18, color: Colors.grey),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white),
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                              fontSize: 11, color: const Color(0xFF888888)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDestinationPreviewCard() {
    return Positioned(
      bottom: 80,
      left: 12,
      right: 12,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 110),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
                color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 4)),
          ],
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.location_on_rounded,
                    color: Colors.redAccent, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _pendingDestName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: (MediaQuery.of(context).size.width - 24 - 24 - 8) * 0.35,
                  height: 40,
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _isPendingRoute = false;
                        _pendingDestName = '';
                        _pendingRouteData = null;
                        _destLat = null;
                        _destLng = null;
                        _destinationController.clear();
                      });
                      _pointManager?.deleteAll();
                      _polylineManager?.deleteAll();
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.grey,
                      side: const BorderSide(color: Colors.grey),
                      shape: const StadiumBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    child: Text("Cancel",
                        style: GoogleFonts.inter(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: ElevatedButton(
                      onPressed: _isRouteFetching ? null : () async {
                        print('=== START JOURNEY TAPPED ===');
                        final supabase = Supabase.instance.client;
                        print('User ID: ${supabase.auth.currentUser?.id}');
                        print('Start: $_startLat, $_startLng');
                        print('Dest: $_destLat, $_destLng');
                        print('Active trip before insert: $_activeTripId');
                        if (_pendingRouteData != null) {
                          // Route already drawn in preview — just activate it
                          setState(() {
                            _isPendingRoute = false;
                            _pendingRouteData = null;
                            _isRouteActive = true;
                            _isTracking = false;
                          });
                        } else {
                          // Fallback: fetch fresh if preview route wasn't cached
                          setState(() => _isPendingRoute = false);
                          _fetchAndDrawRoute(_destLat!, _destLng!);
                        }
                        if (supabase.auth.currentUser != null) {
                          try {
                            print('Attempting trips insert...');
                            final tripResponse = await supabase
                                .from('trips')
                                .insert({
                                  'user_id': supabase.auth.currentUser!.id,
                                  'status': 'active',
                                  'start_location': 'SRID=4326;POINT($_startLng $_startLat)',
                                  'destination': 'SRID=4326;POINT($_destLng $_destLat)',
                                  'started_at': DateTime.now().toIso8601String(),
                                })
                                .select('id')
                                .single();
                            print('Trip insert success: $tripResponse');
                            final String tripId = tripResponse['id'] as String;
                            setState(() { _activeTripId = tripId; });
                            print('Trip created: $tripId');
                            GeofenceService().startTripTracker(tripId, _currentRouteGeometry);
                          } catch (e) {
                            print('Trip insert FAILED: $e');
                            print('Trip insert error type: ${e.runtimeType}');
                          }
                        } else {
                          print('Trip insert skipped — user not authenticated');
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00BCD4),
                        foregroundColor: Colors.white,
                        shape: const StadiumBorder(),
                        elevation: 0,
                        padding: EdgeInsets.zero,
                      ),
                      child: _isRouteFetching
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : Text("Start Journey",
                              style: GoogleFonts.inter(
                                  fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomSheet() {
    if (_isRouteActive) {
      return SingleChildScrollView(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: SentraDesign.uberBlack,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(24),
                  topRight: Radius.circular(24),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Risk badge
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: _riskLevel == 'high'
                                ? const Color(0xFFFF3B30)
                                : _riskLevel == 'medium'
                                    ? const Color(0xFFFF9500)
                                    : const Color(0xFF34C759),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _riskLevel == 'high'
                                ? 'HIGH RISK'
                                : _riskLevel == 'medium'
                                    ? 'CAUTION'
                                    : 'SAFE ROUTE',
                            style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "${_durationMin.toStringAsFixed(0)} min walk",
                          style: GoogleFonts.inter(
                            color: SentraDesign.pureWhite,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_riskExplanation.isNotEmpty)
                          Text(
                            _riskExplanation,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              color: const Color(0xB3FFFFFF),
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.directions_walk,
                    color: _riskLevel == 'high'
                        ? const Color(0xFFFF3B30)
                        : _riskLevel == 'medium'
                            ? const Color(0xFFFF9500)
                            : const Color(0xFF34C759),
                    size: 40,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_highRiskSegmentCount > 0)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0x1AFF3B30),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFF3B30), width: 1.2),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Color(0xFFFF3B30), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "$_highRiskSegmentCount high-risk segment${_highRiskSegmentCount > 1 ? 's' : ''} on this route",
                        style: GoogleFonts.inter(
                          color: const Color(0xFFFF3B30),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (!_isRouteSafe) const SizedBox(height: 12),
            ListTile(
              leading:
                  const Icon(Icons.info_outline, color: SentraDesign.uberBlack),
              title: Text(
                "Route Details",
                style: GoogleFonts.inter(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                "This path avoids ${_riskScore > 0 ? 'detected high-crime zones' : 'all known danger zones'}.",
                style: GoogleFonts.inter(fontSize: 12),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        if (_activeTripId != null) {
                          await Supabase.instance.client
                              .from('trips')
                              .update({
                                'status': 'completed',
                                'updated_at': DateTime.now().toIso8601String(),
                              })
                              .eq('id', _activeTripId!);
                          setState(() { _activeTripId = null; });
                        }
                        GeofenceService().stopTripTracker();
                        setState(() {
                          _isRouteActive = false;
                          _isTracking = false;
                          _isInputExpanded = false;
                          _destinationController.clear();
                          _polylineManager?.deleteAll();
                          _pointManager?.deleteAll();
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: SentraDesign.pureWhite,
                        foregroundColor: SentraDesign.uberBlack,
                        minimumSize: const Size(double.infinity, 50),
                        shape: const StadiumBorder(),
                        side: const BorderSide(color: SentraDesign.uberBlack),
                        elevation: 0,
                      ),
                      child: Text(
                        "Cancel",
                        style: GoogleFonts.inter(
                            color: SentraDesign.uberBlack,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        if (_isTracking) {
                          // End Trip
                          setState(() {
                            _isTracking = false;
                            _isRouteActive = false;
                            _isInputExpanded = false;
                            _destinationController.clear();
                            _polylineManager?.deleteAll();
                            _pointManager?.deleteAll();
                          });
                          if (_activeTripId != null) {
                            print('Trip ended: $_activeTripId');
                            await Supabase.instance.client
                                .from('trips')
                                .update({
                                  'status': 'completed',
                                  'updated_at': DateTime.now().toIso8601String(),
                                })
                                .eq('id', _activeTripId!);
                            setState(() { _activeTripId = null; });
                          }
                          GeofenceService().stopTripTracker();
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text("Arrived. Trip Ended.")));
                        } else {
                          // Start Trip — trip row already created by Start Journey
                          setState(() { _isTracking = true; });
                          if (_activeTripId != null) {
                            GeofenceService().startTripTracker(
                                _activeTripId!, _currentRouteGeometry);
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(
                                    "Tracking Active! Trip ID: ${_activeTripId!.substring(0, 8)}")));
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("Generating Secure Escort Trip...")));
                          }
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isTracking
                            ? SentraDesign.bodyGray
                            : SentraDesign.uberBlack,
                        foregroundColor: SentraDesign.pureWhite,
                        minimumSize: const Size(double.infinity, 50),
                        shape: const StadiumBorder(),
                        elevation: 0,
                      ),
                      child: Text(
                        _isTracking ? "End Trip" : "Start Trip",
                        style: GoogleFonts.inter(
                            color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // ✅ UPDATED: Dynamic Status Panel based on Zone
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            width: double.infinity,
            height: 90,
            decoration: BoxDecoration(
              color: _safetyPanelBg,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(24),
                topRight: Radius.circular(24),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Icon(_safetyIcon,
                            color: _safetyIconColor,
                            size: 18), // ✅ Dynamic Icon
                        const SizedBox(width: 8),
                        Text(
                          _safetyStatusTitle, // ✅ Dynamic Title
                          style: GoogleFonts.inter(
                            color: _safetySecondaryText,
                            fontSize: 12,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _safetyStatusSubtitle, // ✅ Dynamic Subtitle
                      style: GoogleFonts.inter(
                        color: _safetyPrimaryText,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Icon(Icons.battery_saver,
                    color: _safetySecondaryText, size: 28),
              ],
            ),
          ),

          const SizedBox(height: 25),

          // --- TIME SIMULATION SLIDER ---
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Simulation Mode",
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: _toggleSimulationMode,
                  child: Container(
                    width: double.infinity,
                    height: 55,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(30),
                      color: Colors.grey[200],
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Stack(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            Expanded(
                              child: Center(
                                child: Text(
                                  "Day Time",
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: !_isNightMode
                                        ? Colors.black54
                                        : Colors.grey,
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Center(
                                child: Text(
                                  "Night Time",
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: _isNightMode
                                        ? Colors.black54
                                        : Colors.grey,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        AnimatedAlign(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutBack,
                          alignment: _isNightMode
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            width: 160,
                            height: 45,
                            margin: const EdgeInsets.symmetric(horizontal: 5),
                            decoration: BoxDecoration(
                              color: SentraDesign.uberBlack,
                              borderRadius: BorderRadius.circular(25),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.12),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _isNightMode
                                      ? Icons.nights_stay_rounded
                                      : Icons.wb_sunny_rounded,
                                  color: SentraDesign.pureWhite,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _isNightMode ? "Night View" : "Day View",
                                  style: GoogleFonts.inter(
                                    color: SentraDesign.pureWhite,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 25),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 25),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Safe Havens Nearby",
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 15),
                if (_safeHavens.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      "Loading nearby safe places...",
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: Colors.grey[500],
                      ),
                    ),
                  )
                else
                  ..._safeHavens.map((h) => _buildSafePlaceTile(h)),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showProfileSheet() async {
    final user = Supabase.instance.client.auth.currentUser;
    print(
        '[Profile] Fetching profile for user: ${user?.id} | meta_name: ${user?.userMetadata?['full_name']} | phone: ${user?.phone}');
    String? fullName;
    String? phone;
    try {
      if (user != null) {
        final row = await Supabase.instance.client
            .from('profiles')
            .select('full_name,phone')
            .eq('id', user.id)
            .maybeSingle();
        fullName = row?['full_name'] as String?;
        phone = row?['phone'] as String?;
      }
    } catch (_) {}

    // Auth session metadata is always current (set at OTP verify time).
    // Prefer it over the DB row, which may be stale from a previous user.
    final metaName = user?.userMetadata?['full_name'] as String?;
    final authPhone = user?.phone;
    fullName = metaName?.isNotEmpty == true
        ? metaName
        : (fullName?.isNotEmpty == true ? fullName : metaName);
    phone = authPhone?.isNotEmpty == true
        ? authPhone
        : (phone?.isNotEmpty == true ? phone : authPhone);

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: SentraDesign.pureWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Account',
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: SentraDesign.uberBlack,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  fullName ?? '—',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: SentraDesign.uberBlack,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  phone ?? user?.email ?? '—',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: SentraDesign.bodyGray,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'ID: ${user?.id ?? "—"}',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: SentraDesign.mutedGray,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () async {
                      await LocationService().clearLocation();
                      await LocationService().dispose();
                      await Supabase.instance.client.auth.signOut();
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                    child: const Text('Sign out'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildNavBar() {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _navIndex,
        backgroundColor: SentraDesign.pureWhite,
        elevation: 0,
        selectedItemColor: SentraDesign.uberBlack,
        unselectedItemColor: SentraDesign.mutedGray,
        showUnselectedLabels: true,
        selectedLabelStyle: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: GoogleFonts.inter(fontSize: 12),
        onTap: (index) {
          setState(() => _navIndex = index);
          if (index == 1) {
            _handleSosSequence();
          } else if (index == 2) {
            _showProfileSheet();
          }
        },
        items: [
          BottomNavigationBarItem(
            icon: Icon(
              Icons.home_rounded,
              size: 28,
              color: _navIndex == 0
                  ? SentraDesign.uberBlack
                  : SentraDesign.mutedGray,
            ),
            label: "Home",
          ),
          BottomNavigationBarItem(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(
                color: SentraDesign.uberBlack,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.emergency_rounded,
                color: SentraDesign.pureWhite,
                size: 28,
              ),
            ),
            label: "SOS",
          ),
          BottomNavigationBarItem(
            icon: Icon(
              Icons.person_rounded,
              size: 28,
              color: _navIndex == 2
                  ? SentraDesign.uberBlack
                  : SentraDesign.mutedGray,
            ),
            label: "Profile",
          ),
        ],
      ),
    );
  }

  Widget _buildSafePlaceTile(Map<String, dynamic> haven) {
    final String title = haven['name'] as String;
    final double dist = haven['distance'] as double;
    final String address = (haven['address'] as String?) ?? '';
    final String category = (haven['category'] as String?) ?? '';

    IconData icon;
    switch (category) {
      case 'police':
        icon = Icons.local_police;
        break;
      case 'hospital':
        icon = Icons.local_hospital;
        break;
      case 'pharmacy':
        icon = Icons.local_pharmacy;
        break;
      case 'fire_station':
        icon = Icons.fire_truck;
        break;
      default:
        icon = Icons.store_rounded;
    }

    return GestureDetector(
      onTap: () => _selectDestinationFromSafeHaven(
        haven['lat'] as double,
        haven['lng'] as double,
        title,
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: SentraDesign.cardShadow,
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: SentraDesign.chipGray,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: SentraDesign.uberBlack, size: 22),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${dist.toStringAsFixed(1)} km'
                    '${address.isNotEmpty ? ' • $address' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.directions_outlined, color: Colors.grey, size: 20),
          ],
        ),
      ),
    );
  }
}

class SosCountdownDialog extends StatefulWidget {
  final String? triggerReason;
  const SosCountdownDialog({super.key, this.triggerReason});

  static void dismissIfActive() {
    _SosCountdownDialogState.activeInstance?._dismissForOverride();
  }

  @override
  State<SosCountdownDialog> createState() => _SosCountdownDialogState();
}

class _SosCountdownDialogState extends State<SosCountdownDialog>
    with SingleTickerProviderStateMixin {
  static _SosCountdownDialogState? activeInstance;
  late AnimationController _controller;
  int _countdown = 10;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    activeInstance = this;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_countdown > 1) {
          _countdown--;
        } else {
          _timer?.cancel();
          Navigator.of(context).pop(true);
        }
      });
    });
  }

  @override
  void dispose() {
    if (activeInstance == this) {
      activeInstance = null;
    }
    _controller.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _dismissForOverride() {
    _timer?.cancel();
    if (mounted) {
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: SentraDesign.uberBlack,
                borderRadius: BorderRadius.circular(30),
                boxShadow: SentraDesign.cardShadow,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: SentraDesign.pureWhite),
                  const SizedBox(width: 8),
                  Text(
                    widget.triggerReason != null
                        ? "DANGER DETECTED"
                        : "EMERGENCY ALERT",
                    style: GoogleFonts.inter(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            if (widget.triggerReason != null) ...[
              const SizedBox(height: 10),
              Text(
                "Heard: ${widget.triggerReason}",
                style: GoogleFonts.inter(color: Colors.white, fontSize: 16),
              ),
            ],
            const SizedBox(height: 30),
            Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    return Container(
                      width: 180 + (_controller.value * 20),
                      height: 180 + (_controller.value * 20),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(
                          0.12 - (_controller.value * 0.06),
                        ),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.35),
                          width: 1,
                        ),
                      ),
                    );
                  },
                ),
                SizedBox(
                  width: 160,
                  height: 160,
                  child: CircularProgressIndicator(
                    value: _countdown / 10,
                    valueColor:
                        const AlwaysStoppedAnimation(SentraDesign.pureWhite),
                    backgroundColor: Colors.white24,
                    strokeWidth: 8,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "$_countdown",
                      style: GoogleFonts.inter(
                        fontSize: 60,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      "Sending SOS...",
                      style: GoogleFonts.inter(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 40),
            GestureDetector(
              onTap: () {
                _timer?.cancel();
                Navigator.of(context).pop(false);
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: SentraDesign.pureWhite,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Center(
                  child: Text(
                    widget.triggerReason != null
                        ? "I AM SAFE (CANCEL)"
                        : "CANCEL REQUEST",
                    style: GoogleFonts.inter(
                      color: SentraDesign.uberBlack,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DriftSosOverlay extends StatefulWidget {
  final String? dangerReason;
  const DriftSosOverlay({super.key, this.dangerReason});

  static void dismissIfActive() {
    _DriftSosOverlayState.activeInstance?._dismissForOverride();
  }

  @override
  State<DriftSosOverlay> createState() => _DriftSosOverlayState();
}

class _DriftSosOverlayState extends State<DriftSosOverlay> {
  static _DriftSosOverlayState? activeInstance;
  int _countdown = 15;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    activeInstance = this;
    _triggerHaptics();

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _triggerHaptics();
      setState(() {
        if (_countdown > 1) {
          _countdown--;
        } else {
          _timer?.cancel();
          Navigator.of(context).pop(false);
        }
      });
    });
  }

  void _triggerHaptics() {
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(milliseconds: 200), () {
      HapticFeedback.heavyImpact();
    });
  }

  @override
  void dispose() {
    if (activeInstance == this) {
      activeInstance = null;
    }
    _timer?.cancel();
    super.dispose();
  }

  void _dismissForOverride() {
    _timer?.cancel();
    if (mounted) {
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
            child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.warning_rounded,
                color: SentraDesign.pureWhite, size: 80),
            const SizedBox(height: 20),
            Text("ARE YOU SAFE?",
                style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(
                widget.dangerReason ?? "You strayed from your requested path.\nIf you do not respond, we will trigger an SOS dispatch.",
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(color: Colors.white70, fontSize: 16)),
            const SizedBox(height: 50),
            Text("$_countdown",
                style: GoogleFonts.inter(
                    color: SentraDesign.pureWhite,
                    fontSize: 100,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 50),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                  onPressed: () {
                    _timer?.cancel();
                    Navigator.of(context).pop(true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SentraDesign.pureWhite,
                    foregroundColor: SentraDesign.uberBlack,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    shape: const StadiumBorder(),
                    elevation: 0,
                  ),
                  child: Text("I AM SAFE",
                      style: GoogleFonts.inter(
                          color: SentraDesign.uberBlack,
                          fontSize: 24,
                          fontWeight: FontWeight.bold))),
            ),
          ]),
        )));
  }
}

// ── Audio Threat Overlay ──────────────────────────────────────────────────────
// Shown when YAMNet detects a danger sound. Has a 15-second countdown;
// auto-triggers SOS if the user doesn't respond. Red background distinguishes
// it clearly from the route-drift overlay (black background).

class AudioThreatOverlay extends StatefulWidget {
  final String label;
  final double confidence;
  const AudioThreatOverlay({
    super.key,
    required this.label,
    required this.confidence,
  });

  @override
  State<AudioThreatOverlay> createState() => _AudioThreatOverlayState();
}

class _AudioThreatOverlayState extends State<AudioThreatOverlay> {
  int _countdown = 15;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _triggerHaptics();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _triggerHaptics();
      if (!mounted) return;
      setState(() {
        if (_countdown > 1) {
          _countdown--;
        } else {
          _timer?.cancel();
          // Time's up → return false so caller triggers SOS
          Navigator.of(context).pop(false);
        }
      });
    });
  }

  void _triggerHaptics() {
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(milliseconds: 200), () {
      HapticFeedback.heavyImpact();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.mic_off_rounded,
                  color: Colors.white, size: 64),
              const SizedBox(height: 16),
              Text(
                'THREAT DETECTED',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                widget.label.toUpperCase(),
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${(widget.confidence * 100).toStringAsFixed(0)}% confidence',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'An alert has been sent to the command centre.\nRespond or SOS will be triggered automatically.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 40),
              Text(
                '$_countdown',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 88,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 40),
              // I'M SAFE — dismisses without SOS
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    _timer?.cancel();
                    Navigator.of(context).pop(true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFFCC0000),
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: const StadiumBorder(),
                    elevation: 0,
                  ),
                  child: Text(
                    "I'M SAFE",
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // SEND SOS — immediately triggers SOS
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    _timer?.cancel();
                    Navigator.of(context).pop(false);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54, width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: const StadiumBorder(),
                  ),
                  child: Text(
                    'SEND SOS',
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
