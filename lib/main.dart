import 'dart:async';
import 'dart:io' show Platform, File, Directory;
import 'dart:math' show atan2, cos, max, min, pi, sin, sqrt;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:share_plus/share_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:h3_flutter/h3_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:home_widget/home_widget.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_theme.dart';
import 'glow_wave_overlay.dart';
import 'auth_wrapper.dart';
import 'friends_screen.dart';
import 'onboarding_screen.dart';
import 'profile_screen.dart';
import 'proximity_service.dart';
import 'settings_screen.dart';

// ─── Transport Mode Classification ──────────────────────────────────────────
enum TransportMode { stationary, walking, cycling, transit, highway }

enum DataSource { activityRecognition, gpsSpeed, distanceSpeed, fallback }

class TransportModeClassification {
  final TransportMode mode;
  final DataSource primarySource;
  final double? confidence; // 0.0-1.0
  final String reasoning; // For logging
  final double? speedKmh; // Computed speed
  final String? activityType; // Raw activity type from native API
  final double? speedAccuracy; // GPS speed accuracy in m/s

  TransportModeClassification({
    required this.mode,
    required this.primarySource,
    this.confidence,
    required this.reasoning,
    this.speedKmh,
    this.activityType,
    this.speedAccuracy,
  });
}

class ActivityClassifier {
  /// Classifies transport mode using hybrid approach:
  /// 1. Activity Recognition (native API, PRIMARY)
  /// 2. GPS Speed (with confidence check)
  /// 3. Distance/Time calculation (fallback)
  /// 4. Last known mode (ultimate fallback)
  static TransportModeClassification classifyTransportMode({
    required bg.Location location,
    required bg.Location? previousLocation,
    required TransportMode? lastKnownMode,
  }) {
    // Source 1: Activity Recognition (PRIMARY)
    final activityType = location.activity.type;
    if (activityType.isNotEmpty) {
      final classification = _classifyFromActivity(
        activityType,
        location.coords.speed,
        speedAccuracy: location.coords.speedAccuracy,
      );
      if (classification != null) return classification;
    }

    // Source 2: GPS Speed (with confidence check).
    // speed / speedAccuracy are -1 when unavailable, so `speed >= 0` guards
    // that; a negative (unknown) accuracy is treated as acceptable.
    if (location.coords.speed >= 0 && location.coords.speedAccuracy < 15) {
      final speedKmh = location.coords.speed * 3.6;
      final classification = _classifyFromSpeed(speedKmh);
      if (classification != null) return classification;
    }

    // Source 3: Distance/Time fallback
    if (previousLocation != null) {
      try {
        final distance = _distanceBetween(
          previousLocation.coords.latitude,
          previousLocation.coords.longitude,
          location.coords.latitude,
          location.coords.longitude,
        );
        final timeDiffSeconds =
            DateTime.parse(location.timestamp)
                .difference(DateTime.parse(previousLocation.timestamp))
                .inMilliseconds /
            1000.0;
        if (timeDiffSeconds > 0.5) {
          // Avoid division by very small numbers
          final speedKmh = (distance / timeDiffSeconds) * 3.6;
          final classification = _classifyFromSpeed(speedKmh);
          if (classification != null) {
            return classification.copyWith(
              primarySource: DataSource.distanceSpeed,
              reasoning:
                  'Distance-based speed fallback: ${speedKmh.toStringAsFixed(1)} km/h',
            );
          }
        }
      } catch (e) {
        debugPrint('[classifier] Distance calc error: $e');
      }
    }

    // Source 4: Last known mode
    if (lastKnownMode != null) {
      return TransportModeClassification(
        mode: lastKnownMode,
        primarySource: DataSource.fallback,
        confidence: 0.3,
        reasoning: 'Using last known mode (all sources failed)',
        speedKmh: null,
        activityType: null,
        speedAccuracy: null,
      );
    }

    // Ultimate fallback to STATIONARY
    return TransportModeClassification(
      mode: TransportMode.stationary,
      primarySource: DataSource.fallback,
      confidence: 0.1,
      reasoning: 'No data sources available, defaulting to STATIONARY',
      speedKmh: 0,
      activityType: null,
      speedAccuracy: null,
    );
  }

  static TransportModeClassification? _classifyFromActivity(
    String activityType,
    double? gpsSpeedMs, {
    double? speedAccuracy,
  }) {
    switch (activityType.toLowerCase()) {
      case 'still':
        return TransportModeClassification(
          mode: TransportMode.stationary,
          primarySource: DataSource.activityRecognition,
          confidence: 0.95,
          reasoning: 'Activity Recognition: still',
          speedKmh: 0,
          activityType: activityType,
          speedAccuracy: speedAccuracy,
        );
      case 'walking':
        return TransportModeClassification(
          mode: TransportMode.walking,
          primarySource: DataSource.activityRecognition,
          confidence: 0.90,
          reasoning: 'Activity Recognition: walking',
          speedKmh: (gpsSpeedMs ?? 1.4) * 3.6,
          activityType: activityType,
          speedAccuracy: speedAccuracy,
        );
      case 'on_bicycle':
      case 'on_bike':
        return TransportModeClassification(
          mode: TransportMode.cycling,
          primarySource: DataSource.activityRecognition,
          confidence: 0.85,
          reasoning: 'Activity Recognition: on_bicycle',
          speedKmh: (gpsSpeedMs ?? 6.0) * 3.6,
          activityType: activityType,
          speedAccuracy: speedAccuracy,
        );
      case 'in_vehicle':
        // Sub-classify based on speed
        if (gpsSpeedMs != null && gpsSpeedMs >= 0) {
          if (gpsSpeedMs > 22) {
            // > 80 km/h
            return TransportModeClassification(
              mode: TransportMode.highway,
              primarySource: DataSource.activityRecognition,
              confidence: 0.95,
              reasoning:
                  'Activity Recognition: in_vehicle + high speed (${(gpsSpeedMs * 3.6).toStringAsFixed(1)} km/h > 80)',
              speedKmh: gpsSpeedMs * 3.6,
              activityType: activityType,
              speedAccuracy: speedAccuracy,
            );
          } else {
            return TransportModeClassification(
              mode: TransportMode.transit,
              primarySource: DataSource.activityRecognition,
              confidence: 0.92,
              reasoning:
                  'Activity Recognition: in_vehicle + moderate speed (${(gpsSpeedMs * 3.6).toStringAsFixed(1)} km/h)',
              speedKmh: gpsSpeedMs * 3.6,
              activityType: activityType,
              speedAccuracy: speedAccuracy,
            );
          }
        } else {
          // No speed data, assume TRANSIT as safe default
          return TransportModeClassification(
            mode: TransportMode.transit,
            primarySource: DataSource.activityRecognition,
            confidence: 0.80,
            reasoning: 'Activity Recognition: in_vehicle (no speed data)',
            speedKmh: null,
            activityType: activityType,
            speedAccuracy: speedAccuracy,
          );
        }
      default:
        return null; // Unknown activity type, try next source
    }
  }

  static TransportModeClassification? _classifyFromSpeed(double speedKmh) {
    if (speedKmh < 0.5) {
      return TransportModeClassification(
        mode: TransportMode.stationary,
        primarySource: DataSource.gpsSpeed,
        confidence: 0.70,
        reasoning: 'GPS Speed: ${speedKmh.toStringAsFixed(1)} km/h < 0.5',
        speedKmh: speedKmh,
        activityType: null,
        speedAccuracy: null,
      );
    } else if (speedKmh < 4.0) {
      return TransportModeClassification(
        mode: TransportMode.walking,
        primarySource: DataSource.gpsSpeed,
        confidence: 0.65,
        reasoning: 'GPS Speed: ${speedKmh.toStringAsFixed(1)} km/h (0.5-4.0)',
        speedKmh: speedKmh,
        activityType: null,
        speedAccuracy: null,
      );
    } else if (speedKmh < 8.0) {
      return TransportModeClassification(
        mode: TransportMode.cycling,
        primarySource: DataSource.gpsSpeed,
        confidence: 0.60,
        reasoning: 'GPS Speed: ${speedKmh.toStringAsFixed(1)} km/h (4.0-8.0)',
        speedKmh: speedKmh,
        activityType: null,
        speedAccuracy: null,
      );
    } else if (speedKmh < 80.0) {
      return TransportModeClassification(
        mode: TransportMode.transit,
        primarySource: DataSource.gpsSpeed,
        confidence: 0.75,
        reasoning: 'GPS Speed: ${speedKmh.toStringAsFixed(1)} km/h (8.0-80.0)',
        speedKmh: speedKmh,
        activityType: null,
        speedAccuracy: null,
      );
    } else {
      return TransportModeClassification(
        mode: TransportMode.highway,
        primarySource: DataSource.gpsSpeed,
        confidence: 0.85,
        reasoning: 'GPS Speed: ${speedKmh.toStringAsFixed(1)} km/h > 80.0',
        speedKmh: speedKmh,
        activityType: null,
        speedAccuracy: null,
      );
    }
  }

  static double _distanceBetween(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    // Haversine formula
    const earthRadiusKm = 6371;
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusKm * c * 1000; // Return in meters
  }

  static double _toRad(double degrees) => degrees * pi / 180;
}

extension on TransportModeClassification {
  TransportModeClassification copyWith({
    TransportMode? mode,
    DataSource? primarySource,
    double? confidence,
    String? reasoning,
    double? speedKmh,
    String? activityType,
    double? speedAccuracy,
  }) {
    return TransportModeClassification(
      mode: mode ?? this.mode,
      primarySource: primarySource ?? this.primarySource,
      confidence: confidence ?? this.confidence,
      reasoning: reasoning ?? this.reasoning,
      speedKmh: speedKmh ?? this.speedKmh,
      activityType: activityType ?? this.activityType,
      speedAccuracy: speedAccuracy ?? this.speedAccuracy,
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Try loading .env from assets and project root locations
  final candidates = [
    'assets/.env',
    '.env',
    '../.env',
    '../../.env',
    'lib/.env',
  ];
  var loaded = false;

  for (final path in candidates) {
    try {
      final f = File(path);
      if (await f.exists()) {
        await dotenv.load(fileName: path);
        debugPrint('[dotenv] Loaded from $path');
        loaded = true;
        break;
      }
    } catch (e) {
      debugPrint('[dotenv] Failed loading $path: $e');
    }
  }

  if (!loaded) {
    try {
      // Try loading from assets using rootBundle (works on all platforms)
      await dotenv.load(fileName: 'assets/.env');
      debugPrint('[dotenv] Loaded from assets/.env');
      loaded = true;
    } catch (e) {
      debugPrint('[dotenv] No .env found: $e');
    }
  }

  // Log credentials once after successful load
  if (loaded) {
    debugPrint(
      '[dotenv] SUPABASE_URL: '
      '${dotenv.env['SUPABASE_URL'] ?? 'NOT SET'}',
    );
    debugPrint(
      '[dotenv] SUPABASE_ANON_KEY: '
      '${dotenv.env['SUPABASE_ANON_KEY'] != null ? '${dotenv.env['SUPABASE_ANON_KEY']!.substring(0, 8)}...' : 'NOT SET'}',
    );
  }

  // Initialize Supabase if credentials are available
  await _initializeSupabase();

  // Configure home_widget App Group so data is shared with the iOS widget.
  if (Platform.isIOS) {
    await HomeWidget.setAppGroupId('group.com.hangsocial.hang');
  }

  // Load persisted theme preference using secure storage
  const secureStorage = FlutterSecureStorage();
  final savedTheme = await secureStorage.read(key: 'themeMode');
  if (savedTheme == 'light') {
    themeNotifier.value = ThemeMode.light;
  } else if (savedTheme == 'dark') {
    themeNotifier.value = ThemeMode.dark;
  }

  runApp(
    ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, mode, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: mode,
        home: const AppEntry(),
      ),
    ),
  );
}

Future<void> _initializeSupabase() async {
  // Prefer compile-time --dart-define, fall back to .env variables
  const supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  String envUrl = '';
  String envAnon = '';
  try {
    envUrl = dotenv.env['SUPABASE_URL'] ?? '';
    envAnon = dotenv.env['SUPABASE_ANON_KEY'] ?? '';
  } catch (e) {
    debugPrint('[dotenv] env not initialized: $e');
  }

  final effectiveUrl = supabaseUrl.isNotEmpty ? supabaseUrl : envUrl;
  final effectiveAnon = supabaseAnonKey.isNotEmpty ? supabaseAnonKey : envAnon;

  if (effectiveUrl.isEmpty || effectiveAnon.isEmpty) {
    debugPrint('[supabase] No credentials provided - app will be limited');
    return;
  }

  try {
    await Supabase.initialize(url: effectiveUrl, anonKey: effectiveAnon);
    debugPrint('[supabase] Initialized successfully');
  } catch (e, st) {
    debugPrint('[supabase] Initialization failed: $e\n$st');
  }
}

// ─── App entry point: decides onboarding vs. auth ────────────────────────────
// DEBUG RULE: always show onboarding unless the user is already logged in.
class AppEntry extends StatefulWidget {
  const AppEntry({super.key});
  @override
  State<AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<AppEntry> {
  bool _loading = true;
  bool _showOnboarding = true;

  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    final session = Supabase.instance.client.auth.currentSession;
    await Future<void>.delayed(const Duration(seconds: 1));
    if (mounted) {
      setState(() {
        _showOnboarding = session == null;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SplashScreen();
    }
    if (_showOnboarding) {
      return OnboardingScreen(
        onDone: () {
          if (mounted) setState(() => _showOnboarding = false);
        },
      );
    }
    return const PermissionGate(child: AuthWrapper());
  }
}

// ─── Permission Gate: blocks access until location permission is "Always" ─────
class PermissionGate extends StatefulWidget {
  const PermissionGate({required this.child, super.key});
  final Widget child;

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate>
    with WidgetsBindingObserver {
  bool _hasAlwaysPermission = false;
  bool _checking = true;
  Timer? _permissionCheckTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _permissionCheckTimer?.cancel();
    super.dispose();
  }

  // Called when the app resumes from settings/background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[permission] App resumed from background, rechecking...');
      _checkPermission();
    }
  }

  Future<void> _checkPermission() async {
    try {
      final status = await bg.BackgroundGeolocation.requestPermission();
      // Android: 2 = PERMISSION_GRANTED_ALWAYS
      // iOS: 3 = PERMISSION_GRANTED_ALWAYS
      final isAlways = status == 2 || status == 3;
      debugPrint(
        '[permission] Status: $status ${isAlways ? '✅ ALWAYS' : '(not always)'}',
      );
      if (mounted) {
        setState(() {
          _hasAlwaysPermission = isAlways;
          _checking = false;
        });
        if (isAlways) {
          debugPrint(
            '[permission] ✅ Always permission detected! Unlocking app...',
          );
          _permissionCheckTimer?.cancel();
          _permissionCheckTimer = null;
        }
      }
    } catch (e) {
      debugPrint('[permission] Error checking location permission: $e');
      if (mounted) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _openSettings() async {
    try {
      _permissionCheckTimer?.cancel();
      _permissionCheckTimer = null;

      debugPrint('[permission] Opening app settings...');
      if (Platform.isIOS) {
        await launchUrl(
          Uri.parse('app-settings:'),
          mode: LaunchMode.externalApplication,
        );
      } else if (Platform.isAndroid) {
        await launchUrl(
          Uri(scheme: 'package', path: 'com.hangsocial.hang'),
          mode: LaunchMode.externalApplication,
        );
      }

      // Check every 2 seconds for 30 seconds (less frequent, less annoying)
      int checkCount = 0;
      _permissionCheckTimer = Timer.periodic(const Duration(seconds: 2), (
        _,
      ) async {
        checkCount++;
        await _checkPermission();

        // Stop after 15 attempts (~30 seconds)
        if (checkCount >= 15) {
          _permissionCheckTimer?.cancel();
          _permissionCheckTimer = null;
          debugPrint('[permission] ⏱️ Stopped checking after 30s');
        }
      });
    } catch (e) {
      debugPrint('[permission] Error opening settings: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const SplashScreen();
    }

    if (!_hasAlwaysPermission) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.location_off,
                  size: 64,
                  color: Color(0xFFFF8C00),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Location Access Required',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  'hang. requires location access "Always" to detect nearby friends in the background.',
                  style: TextStyle(
                    fontSize: 16,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                ElevatedButton(
                  onPressed: _openSettings,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF8C00),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 14,
                    ),
                  ),
                  child: const Text(
                    'Open Settings',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return widget.child;
  }
}

// ─── Splash screen ───────────────────────────────────────────────────────────
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'hang.',
              style: TextStyle(
                color: Color(0xFFFF8C00),
                fontSize: 52,
                fontWeight: FontWeight.bold,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 48),
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(4, (i) {
                    // Each dot leads the animation by 0.2 of a cycle.
                    final phase = (_controller.value - i * 0.2).clamp(0.0, 1.0);
                    // Sine wave: 0 → up → 0 → down → 0
                    final offset = sin(phase * 2 * pi) * 10.0;
                    final opacity =
                        0.35 + 0.65 * ((sin(phase * 2 * pi) + 1) / 2);
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: Transform.translate(
                        offset: Offset(0, -offset),
                        child: Opacity(
                          opacity: opacity,
                          child: Container(
                            width: 9,
                            height: 9,
                            decoration: const BoxDecoration(
                              color: Color(0xFFFF8C00),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Main app shell ───────────────────────────────────────────────────────────
class HangApp extends StatefulWidget {
  const HangApp({super.key});
  @override
  State<HangApp> createState() => _HangAppState();
}

class _HangAppState extends State<HangApp> {
  int _currentIndex = 0;
  final _radarKey = GlobalKey<_RadarTabState>();
  final _friendsNavKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final screens = [
      _RadarTab(key: _radarKey),
      _FriendsTab(navigatorKey: _friendsNavKey),
      SettingsScreen(
        onRadiusChanged: (k) => _radarKey.currentState?.onRadiusChanged(k),
      ),
    ];
    return Scaffold(
      body: Stack(
        children: [
          // Extend body all the way to the bottom edge so the frosted pill
          // floats over it. Each screen is responsible for its own padding.
          Positioned.fill(
            child: MediaQuery(
              // Give screens a bottom inset equal to safe area + pill height
              // so scroll views naturally scroll clear of the floating navbar.
              data: MediaQuery.of(context).copyWith(
                padding: MediaQuery.of(context).padding.copyWith(
                  bottom: MediaQuery.of(context).padding.bottom + 80,
                ),
              ),
              child: IndexedStack(index: _currentIndex, children: screens),
            ),
          ),
          // Gradient fade at bottom so content doesn't bleed into pill
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 140,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Theme.of(context).scaffoldBackgroundColor,
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Floating pill navbar — positioned above home indicator
          Positioned(
            left: 32,
            right: 32,
            bottom: 24,
            child: _FloatingNavBar(
              currentIndex: _currentIndex,
              onTap: (index) {
                if (index == 1 && _currentIndex == 1) {
                  _friendsNavKey.currentState?.popUntil(
                    (route) => route.isFirst,
                  );
                  return;
                }
                setState(() => _currentIndex = index);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FriendsTab extends StatelessWidget {
  const _FriendsTab({required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Let the nested navigator consume back-gestures first.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) navigatorKey.currentState?.maybePop();
      },
      child: Navigator(
        key: navigatorKey,
        onGenerateRoute: (_) =>
            MaterialPageRoute(builder: (_) => const FriendsScreen()),
      ),
    );
  }
}

class _RadarTab extends StatefulWidget {
  const _RadarTab({super.key});
  @override
  State<_RadarTab> createState() => _RadarTabState();
}

// ─── Floating pill navigation bar ────────────────────────────────────────────

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({required this.currentIndex, required this.onTap});

  final int currentIndex;
  final void Function(int) onTap;

  static const _icons = [Icons.radar, Icons.people, Icons.settings];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(60),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF232323).withOpacity(0.92)
                : Colors.white.withOpacity(0.92),
            borderRadius: BorderRadius.circular(60),
            border: Border.all(
              color: isDark
                  ? Colors.white.withOpacity(0.13)
                  : Colors.black.withOpacity(0.08),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.60 : 0.15),
                blurRadius: 32,
                offset: const Offset(0, 10),
              ),
              BoxShadow(
                color: const Color(0xFFFF8800).withOpacity(0.06),
                blurRadius: 40,
                offset: const Offset(0, 0),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(_icons.length, (i) {
              final active = i == currentIndex;
              return GestureDetector(
                onTap: () => onTap(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOut,
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active
                        ? const Color(0xFFFF8800)
                        : (isDark
                              ? Colors.white.withOpacity(0.07)
                              : Colors.black.withOpacity(0.05)),
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: const Color(0xFFFF8800).withOpacity(0.55),
                              blurRadius: 18,
                              spreadRadius: 1,
                            ),
                          ]
                        : [],
                  ),
                  child: Icon(
                    _icons[i],
                    color: active
                        ? Colors.black
                        : (isDark ? Colors.white54 : Colors.black45),
                    size: 22,
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _RadarTabState extends State<_RadarTab> {
  // Debounce/in-flight guard for friend check
  bool _isCheckingFriends = false;
  H3? h3;
  H3Index? currentH3Index;
  List<H3Index>? currentKRing;
  String sectorText = '';
  String statusText = 'Loading ...';
  bool supabaseAvailable = false;
  String supabaseRawResponse = '';
  List<Map<String, dynamic>> nearbyFriends = [];
  bool _isIncognito = false;
  DateTime? _incognitoUntil;
  bool _isInSafeZone = false;
  bool _isInSilentZone = false;
  String _buildVersionLabel = '';
  int _visibilityRadius = 2; // kRing (1 = ~500m, 2 = ~1.5km, 3 = ~3km)
  bool _radiusLoaded = false;

  // Timestamp (UTC) of the last successful location write to Supabase.
  // Used to relax the accuracy gate when our DB sector has gone stale, so a
  // coarse background fix can still update us instead of leaving the sector
  // frozen for hours.
  DateTime? _lastLocationWriteAt;

  // Debug panel
  final List<String> _debugLog = [];
  bool _showDebug = false;

  // Transport Mode Classification & History
  TransportMode? _currentTransportMode; // Committed mode
  TransportMode? _lastTransportMode; // Pending candidate (hysteresis)
  int _transportModeConfirmationCount = 0; // Hysteresis counter
  int _currentDistanceFilter =
      100; // Current distanceFilter (m), matches Config
  bg.Location? _lastLocationForDistance; // For distance-based speed calculation

  // Set true by onHeartbeat right before its getCurrentPosition() so the
  // resulting _onLocation bypasses the same-cell guard. While sitting still in
  // one H3 cell the guard would otherwise skip both the updated_at write and
  // the friend scan — freezing last_seen_at, letting the 3h cooldown lapse, and
  // risking a departure ping after >=3h together. Forcing the scan lets
  // checkAndPing heartbeat last_seen_at (ping stays suppressed) and keeps our
  // updated_at fresh.
  bool _forceScanFromHeartbeat = false;

  void _dbg(String msg) {
    final ts = DateTime.now().toLocal().toString().substring(11, 19);
    debugPrint('[dbg] $msg');
    _debugLog.insert(0, '[$ts] $msg');
    if (_debugLog.length > 30) _debugLog.removeLast();
    if (mounted) setState(() {});
  }

  /// Fetches the plugin's native SQLite log and shows it in a scrollable
  /// dialog. Unlike the in-memory [_debugLog] (capped at 30 lines and wiped on
  /// every app relaunch), this log is written natively even while the app is
  /// backgrounded or terminated. We constrain this view to the last 24 hours.
  Future<String> _getDeviceLogLast24h() async {
    final end = DateTime.now();
    final start = end.subtract(const Duration(hours: 24));
    return bg.Logger.getLog(
      bg.SQLQuery(start: start, end: end, order: bg.SQLQuery.ORDER_ASC),
    );
  }

  Future<void> _saveDeviceLogAsText(String log, BuildContext ctx) async {
    try {
      final now = DateTime.now().toUtc();
      final yyyy = now.year.toString().padLeft(4, '0');
      final mm = now.month.toString().padLeft(2, '0');
      final dd = now.day.toString().padLeft(2, '0');
      final hh = now.hour.toString().padLeft(2, '0');
      final min = now.minute.toString().padLeft(2, '0');
      final ss = now.second.toString().padLeft(2, '0');
      final stamp = '${yyyy}${mm}${dd}_${hh}${min}${ss}';

      final file = File(
        '${Directory.systemTemp.path}/hang_device_log_last24h_$stamp.txt',
      );
      await file.writeAsString(log);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/plain')],
        subject: 'hang device log (last 24h)',
        text: 'hang device log (last 24h)',
      );

      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Saved as text file: ${file.path}')),
        );
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(
          ctx,
        ).showSnackBar(SnackBar(content: Text('Failed to save log file: $e')));
      }
    }
  }

  Future<void> _showDeviceLog() async {
    String log;
    try {
      log = await _getDeviceLogLast24h();
    } catch (e) {
      log = 'Failed to load device log: $e';
    }
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        return Dialog(
          insetPadding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            height: media.size.height * 0.8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Device log (last 24h)',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.save_alt, size: 18),
                        tooltip: 'Save as .txt',
                        onPressed: () async {
                          await _saveDeviceLogAsText(log, ctx);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      log.isEmpty ? '(log empty)' : log,
                      style: const TextStyle(
                        fontFamily: 'Courier',
                        fontSize: 10,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  bool get hasNearbyFriends => nearbyFriends.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadBuildVersion();
    try {
      h3 = const H3Factory().load();
      _dbg('H3 init: OK');
    } catch (e) {
      _dbg('H3 init FAILED: $e');
      setState(() {
        statusText = 'H3 library could not be loaded.';
      });
    }

    if (Platform.isIOS || Platform.isAndroid) {
      _initBackgroundGeolocation();
    } else {
      setState(() {
        statusText = 'Location only available on mobile devices.';
      });
    }

    // Check Supabase availability synchronously — already initialized in main().
    try {
      Supabase.instance.client;
      supabaseAvailable = true;
    } catch (_) {
      supabaseAvailable = false;
    }
    _loadIncognitoStatus();
    _loadSafeZoneStatus();
    _loadSilentZoneStatus();
    _loadVisibilityRadius();
    _loadLastKnownCell();

    // Initialize proximity notifications (runs once per app session).
    // Forward all proximity log messages into the in-app debug box.
    ProximityService.instance.uiLogger = (msg) => _dbg('prox: $msg');
    // ignore: discarded_futures
    ProximityService.instance.initialize().catchError((e) {
      debugPrint('[proximity] init error: $e');
    });

    // CRITICAL FIX #6: Check app restart cooldown exploit
    // Ensure that restarting the app doesn't bypass proximity cooldowns
    _checkAndEnforceProximityCooldowns();
  }

  /// CRITICAL FIX #6: Enforce proximity cooldowns from database on app startup
  /// This prevents users from bypassing cooldowns by restarting the app
  Future<void> _checkAndEnforceProximityCooldowns() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      // Keep startup guard aligned with the runtime cooldown policy.
      final cooldownDuration = kDebugMode
          ? const Duration(minutes: 1)
          : const Duration(hours: 3);
      final cutoffIso = DateTime.now()
          .toUtc()
          .subtract(cooldownDuration)
          .toIso8601String();

      final recentPings = await Supabase.instance.client
          .from('proximity_pings')
          .select('last_seen_at')
          .or('user_a_id.eq.$userId,user_b_id.eq.$userId')
          .gte('last_seen_at', cutoffIso)
          .limit(1);

      if (recentPings.isEmpty) return;

      // Cooldown is still active for at least one connection.
      // No ping is issued here; this is a pure startup guard.
      _dbg(
        'Proximity cooldown active '
        '(last_seen_at within ${cooldownDuration.inMinutes}min)',
      );
    } catch (e) {
      _dbg('Error checking proximity cooldowns: $e');
    }
  }

  Future<void> _loadBuildVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final label = 'Build ${info.buildNumber}';
      if (!mounted) return;
      setState(() => _buildVersionLabel = label);
    } catch (e) {
      _dbg('Package info unavailable: $e');
    }
  }

  @override
  void dispose() {
    bg.BackgroundGeolocation.removeListener(_onLocation);
    super.dispose();
  }

  // Push current state to the iOS home screen widget.
  Future<void> _updateWidget() async {
    await HomeWidget.saveWidgetData<int>(
      'hang.nearbyCount',
      nearbyFriends.length,
    );
    await HomeWidget.saveWidgetData<String>('hang.statusText', statusText);
    await HomeWidget.saveWidgetData<bool>('hang.isIncognito', _isIncognito);
    await HomeWidget.saveWidgetData<bool>('hang.isSafeZone', _isInSafeZone);
    await HomeWidget.saveWidgetData<String>(
      'hang.lastUpdated',
      DateTime.now().toUtc().toIso8601String(),
    );
    await HomeWidget.updateWidget(iOSName: 'HangWidgetExtension');
  }

  /// Seed [currentH3Index] from the DB so the same-cell guard in [_onLocation]
  /// prevents redundant Supabase writes after an app restart.
  /// Only sets the value if no real GPS fix has arrived yet.
  Future<void> _loadLastKnownCell() async {
    if (h3 == null) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final resp = await Supabase.instance.client
          .from('profiles')
          .select('last_h3_index_res9')
          .eq('id', userId)
          .single();
      final hexStr = resp['last_h3_index_res9'] as String?;
      if (hexStr != null &&
          hexStr.isNotEmpty &&
          mounted &&
          currentH3Index == null) {
        final cell = BigInt.parse(hexStr, radix: 16);
        setState(() => currentH3Index = cell);
        debugPrint('[location] Seeded currentH3Index from DB: $hexStr');
      }
    } catch (e) {
      debugPrint('[location] Failed to seed last known cell: $e');
    }
  }

  Future<void> _loadIncognitoStatus() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final resp = await Supabase.instance.client
          .from('profiles')
          .select('is_incognito, incognito_until')
          .eq('id', userId)
          .single();

      if (mounted) {
        setState(() {
          _isIncognito = resp['is_incognito'] ?? false;
          final until = resp['incognito_until'];
          _incognitoUntil = until != null ? DateTime.parse(until) : null;

          // Check if incognito expired
          if (_isIncognito &&
              _incognitoUntil != null &&
              DateTime.now().toUtc().isAfter(_incognitoUntil!)) {
            _isIncognito = false;
          }

          // Clear nearby friends when incognito is active
          if (_isIncognito) {
            nearbyFriends.clear();
            statusText = 'Radar disabled (Incognito Mode)';
          }
        });
      }
    } catch (e) {
      debugPrint('[radar] Error loading incognito status: $e');
    }
  }

  Future<void> _loadVisibilityRadius() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final resp = await Supabase.instance.client
          .from('profiles')
          .select('visibility_radius')
          .eq('id', userId)
          .single();
      if (mounted) {
        setState(() {
          _visibilityRadius = (resp['visibility_radius'] as int?) ?? 2;
          _radiusLoaded = true;
        });
      }
    } catch (e) {
      debugPrint('[radar] Error loading visibility_radius: $e');
    }
  }

  /// Called by SettingsScreen when the user changes their visibility radius.
  void onRadiusChanged(int k) {
    setState(() => _visibilityRadius = k);
    _refreshSector();
  }

  Future<void> _loadSafeZoneStatus() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      // Compute fresh from the safe_zones table using the current hex.
      // This avoids relying on the potentially stale profiles.is_in_safe_zone
      // column (which only updates on GPS movement).
      final hexIndex = currentH3Index?.toRadixString(16);

      final zones = await Supabase.instance.client
          .from('safe_zones')
          .select('h3_index_res9')
          .eq('user_id', userId);

      bool isInSafeZone = false;
      if (hexIndex != null) {
        for (final zone in zones) {
          final hexes = (zone['h3_index_res9'] as String).split(',');
          if (hexes.contains(hexIndex)) {
            isInSafeZone = true;
            break;
          }
        }
      } else {
        // No GPS fix yet — fall back to the cached DB value.
        final resp = await Supabase.instance.client
            .from('profiles')
            .select('is_in_safe_zone')
            .eq('id', userId)
            .single();
        isInSafeZone = resp['is_in_safe_zone'] ?? false;
      }

      if (mounted) {
        setState(() {
          _isInSafeZone = isInSafeZone;
          if (_isInSafeZone) {
            nearbyFriends.clear();
            statusText = 'Radar disabled (Safe Zone)';
          }
        });
      }
    } catch (e) {
      debugPrint('[radar] Error loading safe zone status: $e');
    }
  }

  Future<void> _loadSilentZoneStatus() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final hexIndex = currentH3Index?.toRadixString(16);

      final zones = await Supabase.instance.client
          .from('silent_zones')
          .select('h3_index_res9')
          .eq('user_id', userId);

      bool isInSilentZone = false;
      if (hexIndex != null) {
        for (final zone in zones) {
          final hexes = (zone['h3_index_res9'] as String).split(',');
          if (hexes.contains(hexIndex)) {
            isInSilentZone = true;
            break;
          }
        }
      } else {
        final resp = await Supabase.instance.client
            .from('profiles')
            .select('is_in_silent_zone')
            .eq('id', userId)
            .single();
        isInSilentZone = resp['is_in_silent_zone'] ?? false;
      }

      if (mounted) {
        setState(() => _isInSilentZone = isInSilentZone);
      }
      ProximityService.instance.updateSilentZoneStatus(isInSilentZone);
    } catch (e) {
      debugPrint('[radar] Error loading silent zone status: $e');
    }
  }

  String _getAgeLabel(String? updatedAtStr) {
    if (updatedAtStr == null) return '?';

    try {
      // Ensure explicit UTC parsing with 'Z' suffix if not present
      String normalized = updatedAtStr;
      if (!updatedAtStr.endsWith('Z') && !updatedAtStr.contains('+')) {
        normalized = '${updatedAtStr}Z';
      }
      final updatedAt = DateTime.parse(normalized).toUtc();
      final age = DateTime.now().toUtc().difference(updatedAt);

      if (age.inMinutes < 10) {
        return '<10m ago';
      } else if (age.inMinutes < 30) {
        return '<30m ago';
      } else if (age.inHours < 1) {
        return '<1h ago';
      } else if (age.inHours < 2) {
        return '<2h ago';
      } else if (age.inHours < 24) {
        return '${age.inHours}h ago';
      } else {
        return '${age.inDays}d ago';
      }
    } catch (e) {
      debugPrint('[location] Error parsing updated_at: $e');
      return '?';
    }
  }

  Future<void> _initBackgroundGeolocation() async {
    try {
      final permissionStatus =
          await bg.BackgroundGeolocation.requestPermission();
      debugPrint('[permission] $permissionStatus');
      if (permissionStatus < 0) {
        if (!mounted) return;
        setState(() {
          statusText = 'Location permission denied.';
        });
        return;
      }
    } catch (e) {
      debugPrint('[permission error] $e');
      if (!mounted) return;
      setState(() {
        statusText = 'Location permission missing.';
      });
      return;
    }

    bg.BackgroundGeolocation.ready(
          bg.Config(
            reset: true,
            desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
            distanceFilter:
                100.0, // Will be updated dynamically based on transport mode
            // Keep distanceFilter fixed at our per-mode value; the plugin
            // otherwise inflates it to 200-400m at speed (elasticity), which
            // delayed proximity detection.
            disableElasticity: true,
            //useSignificantChangesOnly: true,
            stopTimeout:
                3, // Wait 3 minutes of inactivity before shutting down GPS
            stationaryRadius:
                25.0, // Don't wake up GPS until least 25m movement
            stopOnTerminate: false,
            startOnBoot: true,
            debug: false,
            // VERBOSE keeps a native SQLite event log (motion changes, GPS
            // samples, heartbeats, HTTP) retrievable via
            // BackgroundGeolocation.logger.getLog()/emailLog() — essential for
            // diagnosing why background updates stop firing.
            logLevel: bg.Config.LOG_LEVEL_VERBOSE,
            locationAuthorizationRequest: 'Always',
            showsBackgroundLocationIndicator: false,
            heartbeatInterval: 3600,
            geofenceProximityRadius: 0, // Disable geofence radius
          ),
        )
        .then((bg.State state) {
          debugPrint('[location] Background geolocation ready');
          if (mounted) {
            setState(() {
              statusText = 'Location activated';
            });
          }
        })
        .catchError((e) {
          debugPrint(
            '[location] ❌ Background geolocation initialization failed: $e',
          );
          if (mounted) {
            setState(() {
              statusText = 'Location service unavailable: $e';
            });
          }
        });

    bg.BackgroundGeolocation.onLocation(_onLocation, _onLocationError);
    bg.BackgroundGeolocation.onHeartbeat((bg.HeartbeatEvent event) async {
      final ts = DateTime.now().toLocal().toString().substring(11, 19);
      _dbg('📍 HEARTBEAT [$ts] requesting fresh location');
      // Actively fetch a new fix instead of re-scanning the stale cell.
      // getCurrentPosition() persists + emits through the onLocation stream,
      // so _onLocation runs and updates the DB. This is the hourly recovery
      // path for when the OS stops delivering motion-triggered locations.
      // Force the ensuing _onLocation to scan even if we're still in the same
      // cell, so last_seen_at keeps refreshing during a long stationary session.
      _forceScanFromHeartbeat = true;
      try {
        await bg.BackgroundGeolocation.getCurrentPosition(
          desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
          maximumAge: 0,
          samples: 1,
          timeout: 30,
        );
      } catch (e) {
        _dbg('Heartbeat getCurrentPosition failed: $e — using cached sector');
        _refreshSector();
      }
    });
    bg.BackgroundGeolocation.start();

    // Get current position immediately so the stream fires right away.
    // Do NOT call _onLocation directly — the registered stream listener
    // will handle the result, avoiding a double-fire.
    try {
      await bg.BackgroundGeolocation.getCurrentPosition(
        desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
        maximumAge: 0,
        timeout: 30,
      );
    } catch (e) {
      debugPrint('[location] Failed to get current position: $e');
    }
  }

  Future<void> _onLocation(bg.Location location) async {
    final lat = location.coords.latitude;
    final lng = location.coords.longitude;
    final acc = location.coords.accuracy;
    final ts = DateTime.now().toLocal().toString().substring(11, 19);
    final mode = _currentTransportMode?.name ?? 'unknown';
    if (kDebugMode) {
      _dbg(
        '📍 GPS [$ts] ${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)} ±${acc.toStringAsFixed(0)}m mock=${location.mock} | $mode ${_currentDistanceFilter}m',
      );
    } else {
      // Production: log without exact coordinates for privacy
      _dbg(
        '📍 GPS [$ts] accuracy±${acc.toStringAsFixed(0)}m | $mode ${_currentDistanceFilter}m',
      );
    }

    if (h3 == null) {
      _dbg('H3 is null — cannot process location');
      if (mounted) setState(() => statusText = 'H3 not loaded.');
      return;
    }

    if (lat == 0.0 && lng == 0.0) {
      _dbg('Skipping 0,0 coordinates (no GPS fix yet)');
      return;
    }

    // Adapt the plugin's distanceFilter to how the user is moving (walking →
    // tight 100m for prompt meetup detection; faster modes → looser to save
    // battery). Runs on every fix, independent of the same-cell guard below.
    unawaited(_updateTransportModeAndFilter(location));

    const double kMinAccuracyMeters = 250.0;
    // When our DB sector is stale, accept coarser fixes up to this bound so a
    // background network/significant-location-change fix (often >250m) can
    // still update us. A coarse sector beats an hours-frozen one.
    const double kCoarseAccuracyMeters = 1000.0;
    const staleThreshold = Duration(minutes: 30);

    if (acc > kMinAccuracyMeters) {
      final lastWrite = _lastLocationWriteAt;
      final isStale =
          lastWrite == null ||
          DateTime.now().toUtc().difference(lastWrite) > staleThreshold;

      if (!isStale || acc > kCoarseAccuracyMeters) {
        _dbg(
          'Skipping low-accuracy fix: ±${acc.toStringAsFixed(0)}m (stale=$isStale)',
        );
        if (mounted) {
          setState(
            () => statusText =
                'Waiting for GPS fix (±${acc.toStringAsFixed(0)}m)…',
          );
        }
        return;
      }

      // Stale sector + tolerable accuracy → accept the coarse fix anyway.
      _dbg(
        'Accepting coarse fix ±${acc.toStringAsFixed(0)}m — DB sector was stale',
      );
    }

    H3Index cell;
    List<H3Index> kRingCells;
    try {
      cell = h3!.geoToCell(GeoCoord(lat: lat, lon: lng), 9);
      kRingCells = h3!.gridDisk(cell, _visibilityRadius);
      _dbg('H3 OK: ${cell.toRadixString(16)}');
    } catch (e) {
      _dbg('H3 convert error: $e');
      if (mounted) setState(() => statusText = 'H3 error: $e');
      return;
    }

    // Consume the heartbeat force-scan flag: an hourly heartbeat must refresh
    // updated_at + last_seen_at even without a cell change (see field docs).
    final forceScan = _forceScanFromHeartbeat;
    _forceScanFromHeartbeat = false;

    // Skip if we're already in this cell — avoids duplicate Supabase calls
    // when start(), getCurrentPosition() and a cached event all fire at once.
    // A heartbeat-forced scan bypasses this so long stationary sessions still
    // heartbeat last_seen_at (keeping the cooldown alive) and bump updated_at.
    if (cell == currentH3Index && !forceScan) {
      debugPrint('[location] Same cell as before, skipping update');
      return;
    }

    if (mounted) {
      setState(() {
        currentH3Index = cell;
        currentKRing = kRingCells;
        sectorText = cell.toRadixString(16);
        statusText = 'Sector calculated';
      });
    }

    // Update user's location in Supabase immediately (must complete before scanning
    // so is_in_silent_zone is current in both the DB and local state before
    // checkAndPing decides whether to suppress notifications).
    final zoneResults = await _updateUserLocation(cell);

    // Scan immediately on every distanceFilter-driven location update. The
    // in-flight guard in _checkFriendsInKRingFromSupabase prevents overlapping
    // queries, and last_seen_at + cooldown dedupe pings — so scanning on every
    // move gives timely detection without extra pings. distanceFilter (set per
    // transport mode) is now the single lever controlling scan frequency.
    _checkFriendsInKRing(kRingCells, zoneResults);
  }

  /// Maps a transport mode to the distanceFilter (meters) the plugin should
  /// use. Tight while stationary/walking — meetups happen at these speeds and
  /// we want prompt detection — and progressively looser at higher speeds where
  /// 100m granularity is pointless and wastes battery. Elasticity is disabled,
  /// so this is the single source of truth for update frequency.
  int _distanceFilterForMode(TransportMode mode) {
    switch (mode) {
      case TransportMode.stationary:
      case TransportMode.walking:
        return 100;
      case TransportMode.cycling:
        return 150;
      case TransportMode.transit:
        return 300;
      case TransportMode.highway:
        // Deliberately NOT huge (e.g. 50km): _onLocation only fires when this
        // filter is exceeded (elasticity off), and the classifier only runs
        // inside _onLocation. Too large a value means the mode never downgrades
        // to transit/walking while driving into a city — so friend scans stay
        // suppressed until a full stop (motionchange). 2km keeps long-haul DB
        // load low while still reclassifying shortly after the driver slows.
        return 2000;
    }
  }

  /// Classifies the current transport mode and, when it changes (with
  /// hysteresis to avoid setConfig thrashing), reconfigures the plugin's
  /// distanceFilter to match.
  Future<void> _updateTransportModeAndFilter(bg.Location location) async {
    final classification = ActivityClassifier.classifyTransportMode(
      location: location,
      previousLocation: _lastLocationForDistance,
      lastKnownMode: _currentTransportMode,
    );
    _lastLocationForDistance = location;

    final newMode = classification.mode;

    // Already committed to this mode — clear any pending candidate.
    if (newMode == _currentTransportMode) {
      _lastTransportMode = newMode;
      _transportModeConfirmationCount = 0;
      return;
    }

    // Hysteresis: require consecutive confirmations of the same new candidate
    // before committing, so a single noisy reading doesn't thrash setConfig.
    if (newMode == _lastTransportMode) {
      _transportModeConfirmationCount++;
    } else {
      _lastTransportMode = newMode;
      _transportModeConfirmationCount = 1;
    }

    const requiredConfirmations = 2;
    if (_transportModeConfirmationCount < requiredConfirmations) return;

    final previousMode = _currentTransportMode;
    _currentTransportMode = newMode;
    _transportModeConfirmationCount = 0;

    final newFilter = _distanceFilterForMode(newMode);
    if (newFilter == _currentDistanceFilter) {
      _dbg(
        '🚦 $previousMode→$newMode (distanceFilter unchanged ${newFilter}m)',
      );
      return;
    }
    _currentDistanceFilter = newFilter;
    try {
      await bg.BackgroundGeolocation.setConfig(
        bg.Config(distanceFilter: newFilter.toDouble()),
      );
      _dbg(
        '🚦 $previousMode→$newMode | distanceFilter=${newFilter}m | ${classification.reasoning}',
      );
    } catch (e) {
      _dbg('setConfig(distanceFilter=$newFilter) failed: $e');
    }
  }

  /// Returns a map of zone check results {safe, silent} to avoid re-querying
  /// the same data in _checkFriendsInKRing.
  Future<Map<String, dynamic>> _updateUserLocation(H3Index cell) async {
    if (!supabaseAvailable) {
      return {'safe': false, 'silent': false};
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      debugPrint('[location] No authenticated user, skipping location update');
      return {'safe': false, 'silent': false};
    }

    try {
      final hexIndex = cell.toRadixString(16);

      // Check safe zones and silent zones in parallel.
      final results = await Future.wait([
        Supabase.instance.client
            .from('safe_zones')
            .select('h3_index_res9')
            .eq('user_id', user.id),
        Supabase.instance.client
            .from('silent_zones')
            .select('h3_index_res9')
            .eq('user_id', user.id),
      ]);

      final safeZones = results[0] as List;
      final silentZones = results[1] as List;

      bool isInSafeZone = false;
      for (final zone in safeZones) {
        final h3Indices = (zone['h3_index_res9'] as String).split(',');
        if (h3Indices.contains(hexIndex)) {
          isInSafeZone = true;
          break;
        }
      }

      bool isInSilentZone = false;
      for (final zone in silentZones) {
        final h3Indices = (zone['h3_index_res9'] as String).split(',');
        if (h3Indices.contains(hexIndex)) {
          isInSilentZone = true;
          break;
        }
      }

      debugPrint(
        '[location] Updating location: $hexIndex, '
        'safe=$isInSafeZone silent=$isInSilentZone',
      );

      await Supabase.instance.client
          .from('profiles')
          .update({
            'last_h3_index_res9': hexIndex,
            'is_in_safe_zone': isInSafeZone,
            'is_in_silent_zone': isInSilentZone,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', user.id);

      _lastLocationWriteAt = DateTime.now().toUtc();

      if (mounted) {
        setState(() => _isInSilentZone = isInSilentZone);
      }
      ProximityService.instance.updateSilentZoneStatus(isInSilentZone);

      return {'safe': isInSafeZone, 'silent': isInSilentZone};
    } catch (e) {
      _dbg('❌ Failed to update user location: $e');
      return {'safe': false, 'silent': false};
    }
  }

  void _onLocationError(bg.LocationError error) {
    _dbg('Location error ${error.code}: ${error.message}');
    if (mounted) {
      setState(() => statusText = 'Location error: ${error.message}');
    }
  }

  void _checkFriendsInKRing(
    List<H3Index> kRingCells, [
    Map<String, dynamic>? cachedZoneResults,
  ]) {
    if (supabaseAvailable) {
      _checkFriendsInKRingFromSupabase(kRingCells, cachedZoneResults);
      return;
    }

    if (mounted) {
      setState(() {
        nearbyFriends = [];
        statusText = 'Loading ...';
      });
    }
  }

  Future<void> _checkFriendsInKRingFromSupabase(
    List<H3Index> kRingCells, [
    Map<String, dynamic>? cachedZoneResults,
  ]) async {
    // Debounce/in-flight guard
    if (_isCheckingFriends) return;
    _isCheckingFriends = true;
    try {
      final hexesRes9 = kRingCells.map((h) => h.toRadixString(16)).toList();
      if (!supabaseAvailable) return;

      final currentUserId = Supabase.instance.client.auth.currentUser?.id;
      if (currentUserId == null) return;

      // CRITICAL: Load incognito status fresh (not cached), but reuse zone results
      // from _updateUserLocation to avoid re-querying safe_zones/silent_zones.
      await _loadIncognitoStatus();

      // Use cached zone results if available, otherwise load fresh.
      bool isInSafeZone = cachedZoneResults?['safe'] ?? false;
      bool isInSilentZone = cachedZoneResults?['silent'] ?? false;

      if (cachedZoneResults == null) {
        // Fallback: load zones fresh if not passed in (e.g., from older code paths).
        await _loadSafeZoneStatus();
        await _loadSilentZoneStatus();
      } else {
        // Update local state with cached results.
        if (mounted) {
          setState(() {
            _isInSafeZone = isInSafeZone;
            _isInSilentZone = isInSilentZone;
          });
        }
        ProximityService.instance.updateSilentZoneStatus(isInSilentZone);
      }

      // Disable friend detection when incognito
      if (_isIncognito) {
        debugPrint('[radar] Incognito Mode active - Friend detection disabled');
        if (mounted) {
          setState(() {
            nearbyFriends = [];
            statusText = 'Incognito Mode: Radar disabled';
          });
        }
        return;
      }

      // Disable friend detection when in safe zone
      if (_isInSafeZone) {
        debugPrint('[radar] Safe Zone active - Friend detection disabled');
        if (mounted) {
          setState(() {
            nearbyFriends = [];
            statusText = 'Safe Zone: Radar disabled';
          });
        }
        return;
      }

      debugPrint(
        '[supabase] Checking friends in kRing (${hexesRes9.length} cells)',
      );
      // --- Combined friendship query ---
      final friendships = await Supabase.instance.client
          .from('friendships')
          .select('requester_id, addressee_id')
          .or('requester_id.eq.$currentUserId,addressee_id.eq.$currentUserId')
          .eq('status', 'accepted');

      final friendIds = <String>{};
      for (final item in friendships) {
        final map = Map<String, dynamic>.from(item as Map);
        final requester = map['requester_id'] as String?;
        final addressee = map['addressee_id'] as String?;
        if (requester != null && requester != currentUserId) {
          friendIds.add(requester);
        }
        if (addressee != null && addressee != currentUserId) {
          friendIds.add(addressee);
        }
      }

      if (friendIds.isEmpty) {
        debugPrint('[supabase] No accepted friends found');
        if (!mounted) return;
        setState(() {
          nearbyFriends = [];
          statusText = 'No friends nearby.';
          supabaseRawResponse = 'No accepted friends';
        });
        return;
      }

      // Query profiles that are friends AND NOT in safe zone.
      final resp = await Supabase.instance.client
          .from('profiles')
          .select(
            'handle,last_h3_index_res9,id,updated_at,is_in_safe_zone,is_in_silent_zone,is_incognito,incognito_until,visibility_radius,avatar_url',
          )
          .inFilter('id', friendIds.toList())
          .eq('is_in_safe_zone', false)
          .timeout(const Duration(seconds: 15));

      final now = DateTime.now().toUtc();
      final visibleFriends = resp.where((friend) {
        // Incognito check with UTC timestamp parsing
        final isIncognito = friend['is_incognito'] ?? false;
        if (isIncognito) {
          final untilStr = friend['incognito_until'];
          if (untilStr == null) return false;
          // Ensure explicit UTC parsing with 'Z' suffix if not present
          String normalized = untilStr;
          if (!untilStr.endsWith('Z') && !untilStr.contains('+')) {
            normalized = '${untilStr}Z';
          }
          final until = DateTime.parse(normalized).toUtc();
          if (!now.isAfter(until)) return false;
        }

        final friendHex = friend['last_h3_index_res9'] as String?;
        if (friendHex == null) return false;

        // Per-friend effective kRing: privacy-first (minimum wins)
        if (currentH3Index == null || h3 == null) {
          return hexesRes9.contains(friendHex);
        }
        final friendK = (friend['visibility_radius'] as int?) ?? 2;
        final effectiveK = _visibilityRadius < friendK
            ? _visibilityRadius
            : friendK;
        final cells = h3!.gridDisk(currentH3Index!, effectiveK);
        return cells.map((c) => c.toRadixString(16)).contains(friendHex);
      }).toList();

      debugPrint('[supabase] Found \\${visibleFriends.length} visible friends');
      if (!mounted) return;

      setState(() {
        supabaseRawResponse = visibleFriends.toString();
      });

      if (visibleFriends.isEmpty) {
        if (!mounted) return;
        setState(() {
          nearbyFriends = [];
          statusText = 'No friends nearby.';
        });
        return;
      }

      final friends = <Map<String, dynamic>>[];
      for (final row in visibleFriends) {
        final map = Map<String, dynamic>.from(row as Map);
        final handle = map['handle'] as String?;
        final updatedAt = map['updated_at'] as String?;
        final id = map['id'] as String?;
        final isInSilentZone = map['is_in_silent_zone'] as bool? ?? false;
        final rawAvatarUrl = map['avatar_url'] as String?;
        String? avatarUrl;
        if (rawAvatarUrl != null) {
          avatarUrl = rawAvatarUrl.startsWith('http')
              ? rawAvatarUrl
              : Supabase.instance.client.storage
                    .from('avatars')
                    .getPublicUrl(rawAvatarUrl);
        }
        if (handle != null) {
          friends.add({
            'id': id,
            'handle': handle,
            'updated_at': updatedAt,
            'is_in_silent_zone': isInSilentZone,
            'avatar_url': avatarUrl,
          });
        }
      }

      if (!mounted) return;
      setState(() {
        nearbyFriends = friends;
        if (nearbyFriends.isNotEmpty) {
          statusText = nearbyFriends.length == 1
              ? 'There is 1 friend nearby.'
              : 'There are ${nearbyFriends.length} friends nearby.';
        } else {
          statusText = 'No friends nearby.';
        }
      });

      _updateWidget();

      // Always call checkAndPing (even when empty) so the service can clear
      // its "last nearby" set when friends leave — preventing departure pings.
      ProximityService.instance.checkAndPing(
        friends,
        currentUserInSilentZone: _isInSilentZone,
      );
    } on TimeoutException catch (e, st) {
      debugPrint('[supabase] Query timeout: $e\n$st');
      if (!mounted) return;
      setState(() {
        statusText = 'Connection timeout (please try again later).';
        supabaseRawResponse = 'Timeout: $e';
      });
    } catch (e, st) {
      debugPrint('[supabase] Query error: $e\n$st');
      if (!mounted) return;
      setState(() {
        statusText = 'Error querying friends.';
        supabaseRawResponse = '$e';
      });
    } finally {
      _isCheckingFriends = false;
    }
  }

  Future<void> _refreshSector() async {
    if (h3 == null) {
      if (mounted) {
        setState(() {
          statusText = 'H3 not available — cannot calculate sector.';
        });
      }
      return;
    }

    if (currentH3Index == null) {
      // Don't overwrite a "Waiting for GPS fix" message — location events
      // are already running, just no accurate fix yet.
      return;
    }

    try {
      final kRingCells = h3!.gridDisk(currentH3Index!, _visibilityRadius);
      if (mounted) {
        setState(() {
          currentKRing = kRingCells;
          sectorText = currentH3Index!.toRadixString(16);
          statusText = 'Sector updated';
        });
      }
      _checkFriendsInKRing(kRingCells);
    } catch (e) {
      debugPrint('[h3_ffi] gridDisk error: $e');
      if (mounted) {
        setState(() {
          statusText = 'Error calculating sector.';
        });
      }
    }
  }

  Future<void> _setTestLocation() async {
    const testLat = 52.5200;
    const testLng = 13.4050;

    debugPrint('[test] Setting test location: $testLat, $testLng');

    if (h3 == null) {
      debugPrint('[test] H3 not available');
      return;
    }

    try {
      final cell = h3!.geoToCell(GeoCoord(lat: testLat, lon: testLng), 9);
      final kRingCells = h3!.gridDisk(cell, _visibilityRadius);

      if (mounted) {
        setState(() {
          currentH3Index = cell;
          currentKRing = kRingCells;
          sectorText = cell.toRadixString(16);
          statusText = 'Test location: Berlin';
        });
      }

      // Update user's location in Supabase (await so silent zone status is
      // current before checkAndPing runs).
      final zoneResults = await _updateUserLocation(cell);

      _checkFriendsInKRing(kRingCells, zoneResults);
    } catch (e) {
      debugPrint('[test] Error setting test location: $e');
    }
  }

  void _showSectorBanner(String sector) {
    final overlay = Overlay.of(context);

    final overlayEntry = OverlayEntry(
      builder: (ctx) {
        return Positioned(
          top: MediaQuery.of(ctx).padding.top + 10,
          left: 24,
          right: 24,
          child: SafeArea(
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color.fromRGBO(255, 255, 255, 0.98),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    const BoxShadow(color: Colors.black26, blurRadius: 10),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Sector',
                            style: TextStyle(
                              color: Colors.black54,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            sector,
                            style: const TextStyle(
                              fontFamily: 'Courier',
                              color: Colors.black87,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, color: Colors.black54),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: sector));
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                            content: Text('Sector copied to clipboard'),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(overlayEntry);
    Future.delayed(const Duration(seconds: 3), overlayEntry.remove);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: const Text('hang.'),
        actions: [
          if (_buildVersionLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  _buildVersionLabel,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.65),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshSector,
        color: const Color(0xFFFF8C00),
        backgroundColor: const Color(0xFF111111),
        displacement: 60,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.of(context).padding.bottom,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Safe Zone Banner
              if (_isInSafeZone)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A3A3D),
                    border: Border.all(
                      color: const Color(0xFF4DD0E1),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.shield,
                        color: Color(0xFF4DD0E1),
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Safe Zone active',
                              style: TextStyle(
                                color: Color(0xFF4DD0E1),
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Radar disabled - You are protected',
                              style: TextStyle(
                                color: Color(0xFF4DD0E1).withValues(alpha: 0.7),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

              // Silent Zone Banner
              if (_isInSilentZone && !_isInSafeZone && !_isIncognito)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D1E35),
                    border: Border.all(
                      color: const Color(0xFF5B9BD5),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.notifications_off,
                        color: Color(0xFF5B9BD5),
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Silent Zone active',
                              style: TextStyle(
                                color: Color(0xFF5B9BD5),
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Still visible - Pings muted',
                              style: TextStyle(
                                color: const Color(
                                  0xFF5B9BD5,
                                ).withValues(alpha: 0.7),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

              // Inkognito Banner
              if (_isIncognito)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    color: Colors.deepPurple.withValues(alpha: 0.2),
                    border: Border.all(color: Colors.deepPurple, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.visibility_off,
                        color: Colors.deepPurple,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Incognito Mode active',
                              style: TextStyle(
                                color: Colors.deepPurple,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Radar disabled - You are invisible',
                              style: TextStyle(
                                color: Colors.deepPurple[200],
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

              SizedBox(
                width: 320,
                height: 320,
                child: GestureDetector(
                  onLongPress: () {
                    final id = currentH3Index != null
                        ? currentH3Index!.toRadixString(16)
                        : 'No sector';
                    _showSectorBanner(id);
                  },
                  child: Stack(
                    children: [
                      // Hexagons at bottom layer
                      SizedBox.expand(
                        child: _radiusLoaded
                            ? CustomPaint(
                                painter: HexagonGridPainter(
                                  hasNearbyFriends: hasNearbyFriends,
                                  isIncognito: _isIncognito,
                                  isInSafeZone: _isInSafeZone,
                                  isInSilentZone: _isInSilentZone,
                                  visibilityRadius: _visibilityRadius,
                                  isDark:
                                      Theme.of(context).brightness ==
                                      Brightness.dark,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      // Glow wave on top (BlendMode.plus adds light without covering)
                      if (!_isIncognito && !_isInSafeZone)
                        SizedBox.expand(
                          child: GlowWaveOverlay(
                            isActive: hasNearbyFriends,
                            color: _isInSilentZone
                                ? const Color(0xFF5B9BD5)
                                : const Color(0xFFFF8800),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                statusText,
                style: TextStyle(
                  color: hasNearbyFriends
                      ? (_isInSilentZone
                            ? (Theme.of(context).brightness == Brightness.dark
                                  ? const Color(0xFF5B9BD5)
                                  : const Color(0xFF1565C0))
                            : const Color(0xFFFF8A00))
                      : Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.7),
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => setState(() => _showDebug = !_showDebug),
                child: Text(
                  _showDebug ? 'hide debug ▲' : 'debug ▼',
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.2),
                    fontSize: 11,
                  ),
                ),
              ),
              if (_showDebug)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.08),
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _debugLog
                        .map(
                          (line) => Text(
                            line,
                            style: TextStyle(
                              fontFamily: 'Courier',
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.5),
                              fontSize: 10,
                              height: 1.5,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              if (_showDebug && (Platform.isIOS || Platform.isAndroid))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextButton.icon(
                    onPressed: _showDeviceLog,
                    icon: const Icon(Icons.description_outlined, size: 16),
                    label: const Text('View device log (persisted)'),
                  ),
                ),
              const SizedBox(height: 8),
              // Debug: Test location button (only on non-mobile platforms)
              if (!Platform.isIOS && !Platform.isAndroid) ...[
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _setTestLocation,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[800],
                    foregroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 12,
                    ),
                  ),
                  child: const Text('🧪 Set Test Location (Berlin)'),
                ),
              ],
              const SizedBox(height: 24),
              // Only show friends nearby section when not incognito and not in safe zone
              if (!_isIncognito && !_isInSafeZone && nearbyFriends.isNotEmpty)
                ...nearbyFriends.map((friend) {
                  final handle = friend['handle'] as String;
                  final updatedAt = friend['updated_at'] as String?;
                  final ageLabel = _getAgeLabel(updatedAt);
                  final friendId = friend['id'] as String?;
                  final avatarUrl = friend['avatar_url'] as String?;
                  final accentColor = _isInSilentZone
                      ? (Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF5B9BD5)
                            : const Color(0xFF1565C0))
                      : const Color(0xFFFF8A00);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: GestureDetector(
                      onTap: friendId == null
                          ? null
                          : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ProfileScreen(
                                  userId: friendId,
                                  handle: handle,
                                ),
                              ),
                            ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: accentColor.withValues(alpha: 0.2),
                            backgroundImage: avatarUrl != null
                                ? NetworkImage(avatarUrl)
                                : null,
                            child: avatarUrl == null
                                ? Text(
                                    handle.isNotEmpty
                                        ? handle[0].toUpperCase()
                                        : '?',
                                    style: TextStyle(
                                      color: accentColor,
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  )
                                : null,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '@$handle',
                            style: TextStyle(
                              color: accentColor,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '•',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.2),
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            ageLabel,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.35),
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }
}

class HexagonGridPainter extends CustomPainter {
  final bool hasNearbyFriends;
  final bool isIncognito;
  final bool isInSafeZone;
  final bool isInSilentZone;
  final int visibilityRadius;
  final bool isDark;

  HexagonGridPainter({
    required this.hasNearbyFriends,
    this.isIncognito = false,
    this.isInSafeZone = false,
    this.isInSilentZone = false,
    this.visibilityRadius = 2,
    this.isDark = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final side = min(size.width, size.height) * 0.085;
    final spacingX = side * sqrt(3);
    final spacingY = side * 1.5;
    final k = visibilityRadius;

    for (var q = -k; q <= k; q++) {
      for (var r = max(-k, -q - k); r <= min(k, -q + k); r++) {
        final isCore = q == 0 && r == 0;
        final x = (q + r / 2) * spacingX;
        final y = r * spacingY;
        final cellCenter = center + Offset(x, y);

        Color fillColor;
        Color borderColor;
        if (isCore) {
          if (isIncognito) {
            fillColor = const Color(0xFF2D1B3D);
            borderColor = Colors.deepPurple;
          } else if (isInSafeZone) {
            fillColor = const Color(0xFF1A3A3D);
            borderColor = const Color(0xFF4DD0E1);
          } else if (isInSilentZone) {
            fillColor = hasNearbyFriends
                ? const Color(0xFF0D1E35)
                : const Color(0xFF081525);
            borderColor = const Color(0xFF5B9BD5);
          } else {
            fillColor = hasNearbyFriends
                ? const Color(0xFFFF8A00)
                : const Color(0xFF311B00);
            borderColor = hasNearbyFriends
                ? const Color(0xFFFF8A00)
                : (isDark ? Colors.white70 : Colors.black38);
          }
        } else {
          fillColor = isDark
              ? const Color(0xFF111111)
              : const Color(0xFFD4D4D8);
          borderColor = isDark ? Colors.white10 : Colors.black12;
        }

        final path = _hexagonPath(cellCenter, side);
        canvas.drawPath(path, Paint()..color = fillColor);
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = isCore ? 4 : 2
            ..color = borderColor,
        );
      }
    }
  }

  Path _hexagonPath(Offset center, double side) {
    final path = Path();
    for (var i = 0; i < 6; i++) {
      final angle = pi / 6 + i * pi / 3;
      final point = Offset(
        center.dx + side * cos(angle),
        center.dy + side * sin(angle),
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant HexagonGridPainter oldDelegate) {
    return oldDelegate.hasNearbyFriends != hasNearbyFriends ||
        oldDelegate.isIncognito != isIncognito ||
        oldDelegate.isInSafeZone != isInSafeZone ||
        oldDelegate.isInSilentZone != isInSilentZone ||
        oldDelegate.visibilityRadius != visibilityRadius ||
        oldDelegate.isDark != isDark;
  }
}
