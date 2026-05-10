import 'dart:async';
import 'dart:io' show Platform, File;
import 'dart:math' show cos, max, min, pi, sin, sqrt;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:h3_flutter/h3_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:home_widget/home_widget.dart';
import 'app_theme.dart';
import 'glow_wave_overlay.dart';
import 'auth_wrapper.dart';
import 'friends_screen.dart';
import 'onboarding_screen.dart';
import 'profile_screen.dart';
import 'proximity_service.dart';
import 'settings_screen.dart';

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

  // Load persisted theme preference.
  final prefs = await SharedPreferences.getInstance();
  final savedTheme = prefs.getString('themeMode');
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
    return const AuthWrapper();
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
  int _visibilityRadius = 2; // kRing (1 = ~500m, 2 = ~1.5km, 3 = ~3km)
  bool _radiusLoaded = false;

  // Debug panel
  final List<String> _debugLog = [];
  bool _showDebug = false;

  void _dbg(String msg) {
    final ts = DateTime.now().toLocal().toString().substring(11, 19);
    debugPrint('[dbg] $msg');
    _debugLog.insert(0, '[$ts] $msg');
    if (_debugLog.length > 30) _debugLog.removeLast();
    if (mounted) setState(() {});
  }

  bool get hasNearbyFriends => nearbyFriends.isNotEmpty;

  @override
  void initState() {
    super.initState();
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
      final updatedAt = DateTime.parse(updatedAtStr).toUtc();
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
        distanceFilter: 250.0,
        useSignificantChangesOnly: true,
        stopOnTerminate: false,
        startOnBoot: true,
        debug: false,
        logLevel: bg.Config.LOG_LEVEL_OFF,
        locationAuthorizationRequest: 'Always',
        showsBackgroundLocationIndicator: false,
        heartbeatInterval: 60,
      ),
    ).then((bg.State state) {
      debugPrint('[location] Background geolocation ready');
      if (mounted) {
        setState(() {
          statusText = 'Location activated';
        });
      }
    });

    bg.BackgroundGeolocation.onLocation(_onLocation, _onLocationError);
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
    _dbg(
      'GPS ${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)} ±${acc.toStringAsFixed(0)}m mock=${location.mock}',
    );

    if (h3 == null) {
      _dbg('H3 is null — cannot process location');
      if (mounted) setState(() => statusText = 'H3 not loaded.');
      return;
    }

    if (lat == 0.0 && lng == 0.0) {
      _dbg('Skipping 0,0 coordinates (no GPS fix yet)');
      return;
    }

    const double kMinAccuracyMeters = 250.0;
    if (acc > kMinAccuracyMeters) {
      _dbg('Skipping low-accuracy fix: ±${acc.toStringAsFixed(0)}m');
      if (mounted) {
        setState(
          () =>
              statusText = 'Waiting for GPS fix (±${acc.toStringAsFixed(0)}m)…',
        );
      }
      return;
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

    // Skip if we're already in this cell — avoids duplicate Supabase calls
    // when start(), getCurrentPosition() and a cached event all fire at once.
    if (cell == currentH3Index) {
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

    // Update user's location in Supabase (must complete before scanning
    // so is_in_silent_zone is current in both the DB and local state before
    // checkAndPing decides whether to suppress notifications).
    await _updateUserLocation(cell);

    _checkFriendsInKRing(kRingCells);
  }

  Future<void> _updateUserLocation(H3Index cell) async {
    if (!supabaseAvailable) return;

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      debugPrint('[location] No authenticated user, skipping location update');
      return;
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

      if (mounted) {
        setState(() => _isInSilentZone = isInSilentZone);
      }
      ProximityService.instance.updateSilentZoneStatus(isInSilentZone);
    } catch (e) {
      debugPrint('[location] Failed to update user location: $e');
    }
  }

  void _onLocationError(bg.LocationError error) {
    _dbg('Location error ${error.code}: ${error.message}');
    if (mounted) {
      setState(() => statusText = 'Location error: ${error.message}');
    }
  }

  void _checkFriendsInKRing(List<H3Index> kRingCells) {
    if (supabaseAvailable) {
      _checkFriendsInKRingFromSupabase(kRingCells);
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
    List<H3Index> kRingCells,
  ) async {
    // Reload incognito and safe zone status before checking friends
    await _loadIncognitoStatus();
    await _loadSafeZoneStatus();
    await _loadSilentZoneStatus();

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

    final hexesRes9 = kRingCells.map((h) => h.toRadixString(16)).toList();
    if (!supabaseAvailable) return;

    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null) return;

    debugPrint(
      '[supabase] Checking friends in kRing (${hexesRes9.length} cells)',
    );
    try {
      // Get list of accepted friend IDs
      final friendshipsAsRequester = await Supabase.instance.client
          .from('friendships')
          .select('addressee_id')
          .eq('requester_id', currentUserId)
          .eq('status', 'accepted');

      final friendshipsAsAddressee = await Supabase.instance.client
          .from('friendships')
          .select('requester_id')
          .eq('addressee_id', currentUserId)
          .eq('status', 'accepted');

      final friendIds = <String>{};
      for (final item in friendshipsAsRequester) {
        final map = Map<String, dynamic>.from(item as Map);
        final id = map['addressee_id'] as String?;
        if (id != null) friendIds.add(id);
      }
      for (final item in friendshipsAsAddressee) {
        final map = Map<String, dynamic>.from(item as Map);
        final id = map['requester_id'] as String?;
        if (id != null) friendIds.add(id);
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
      // Also fetch visibility_radius so we can apply min-kRing (privacy wins).
      // is_in_silent_zone is fetched so ping suppression can check it per-friend.
      final resp = await Supabase.instance.client
          .from('profiles')
          .select(
            'handle,last_h3_index_res9,id,updated_at,is_in_safe_zone,is_in_silent_zone,is_incognito,incognito_until,visibility_radius,avatar_url',
          )
          .inFilter('id', friendIds.toList())
          .eq('is_in_safe_zone', false)
          .timeout(const Duration(seconds: 15));

      // For each friend apply effectiveK = min(my radius, friend's radius)
      // individually — building a union first is wrong because a large radius
      // from one friend would bleed into the check for a short-radius friend.
      final now = DateTime.now().toUtc();
      final visibleFriends = resp.where((friend) {
        // Incognito check
        final isIncognito = friend['is_incognito'] ?? false;
        if (isIncognito) {
          final untilStr = friend['incognito_until'];
          if (untilStr == null) return false;
          final until = DateTime.parse(untilStr);
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

      debugPrint('[supabase] Found ${visibleFriends.length} visible friends');
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
      await _updateUserLocation(cell);

      _checkFriendsInKRing(kRingCells);
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
      appBar: AppBar(elevation: 0, title: const Text('hang.')),
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
