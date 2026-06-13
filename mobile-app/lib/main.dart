import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'repositories/profile_repository.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_emergency_contact_screen.dart';
import 'screens/onboarding_personal_info_screen.dart';
import 'services/location_service.dart';
import 'theme/sentra_design.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(fileName: ".env");

  final mapboxToken = dotenv.env['MAPBOX_ACCESS_TOKEN'] ?? '';
  if (mapboxToken.isNotEmpty) {
    MapboxOptions.setAccessToken(mapboxToken);
  }

  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL'] ?? '',
    anonKey: dotenv.env['SUPABASE_ANON_KEY'] ?? '',
  );

  runApp(const SentraApp());
}

class SentraApp extends StatelessWidget {
  const SentraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SENTRA',
      debugShowCheckedModeBanner: false,
      theme: SentraDesign.buildTheme(),
      home: const AuthShell(),
    );
  }
}

// ── Onboarding routing state ──────────────────────────────────────────────────

enum _OnboardingStep {
  checking,          // async profile check in progress
  needsPersonalInfo, // Step 1 not done
  needsEmergencyContact, // Step 1 done, Step 2 not done
  complete,          // both steps done → HomeScreen
}

// ── AuthShell ─────────────────────────────────────────────────────────────────

class AuthShell extends StatefulWidget {
  const AuthShell({super.key});

  @override
  State<AuthShell> createState() => _AuthShellState();
}

class _AuthShellState extends State<AuthShell> {
  late final StreamSubscription<AuthState> _authSub;

  Session? _session;
  _OnboardingStep _step = _OnboardingStep.checking;

  @override
  void initState() {
    super.initState();
    _session = Supabase.instance.client.auth.currentSession;

    // If the app was opened with an existing session, kick off the check now.
    if (_session != null) {
      _checkOnboardingStatus(_session!.user.id);
    } else {
      _step = _OnboardingStep.complete; // state irrelevant when not signed in
    }

    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (!mounted) return;

      if (data.session == null && _session != null) {
        // Session ended — clear live-location beacon and stop tracking.
        LocationService().clearLocation();
        setState(() {
          _session = null;
          _step = _OnboardingStep.complete; // reset; LoginScreen doesn't use it
        });
        return;
      }

      if (data.session != null && data.session!.user.id != _session?.user.id) {
        // New sign-in (or token refresh for a different user) — re-check profile.
        setState(() {
          _session = data.session;
          _step = _OnboardingStep.checking;
        });
        _checkOnboardingStatus(data.session!.user.id);
        return;
      }

      setState(() => _session = data.session);
    });
  }

  Future<void> _checkOnboardingStatus(String userId) async {
    try {
      final personalDone =
          await ProfileRepository.instance.isPersonalInfoComplete(userId);

      if (!mounted) return;

      if (!personalDone) {
        setState(() => _step = _OnboardingStep.needsPersonalInfo);
        return;
      }

      final contactDone =
          await ProfileRepository.instance.hasEmergencyContact(userId);

      if (!mounted) return;

      setState(() => _step = contactDone
          ? _OnboardingStep.complete
          : _OnboardingStep.needsEmergencyContact);
    } catch (_) {
      // Network failure during check — let the user through rather than
      // blocking them on a loading spinner indefinitely.
      if (mounted) setState(() => _step = _OnboardingStep.complete);
    }
  }

  @override
  void dispose() {
    _authSub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Not signed in.
    if (_session == null) {
      return const LoginScreen();
    }

    // Signed in — route based on onboarding state.
    switch (_step) {
      case _OnboardingStep.checking:
        return const _LoadingShell();

      case _OnboardingStep.needsPersonalInfo:
        return OnboardingPersonalInfoScreen(
          onComplete: () {
            final userId = _session?.user.id;
            if (userId == null) return;
            setState(() => _step = _OnboardingStep.checking);
            _checkOnboardingStatus(userId);
          },
        );

      case _OnboardingStep.needsEmergencyContact:
        return OnboardingEmergencyContactScreen(
          onComplete: () =>
              setState(() => _step = _OnboardingStep.complete),
        );

      case _OnboardingStep.complete:
        return const HomeScreen();
    }
  }
}

// ── Thin loading screen shown while the profile check runs ───────────────────

class _LoadingShell extends StatelessWidget {
  const _LoadingShell();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: SentraDesign.pureWhite,
      body: Center(
        child: CircularProgressIndicator(color: SentraDesign.uberBlack),
      ),
    );
  }
}
