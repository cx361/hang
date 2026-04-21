import 'dart:async';
import 'dart:io' show Platform, File;
import 'dart:math' show cos, max, min, pi, sin, sqrt;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:h3_flutter/h3_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'glow_wave_overlay.dart';
import 'auth_wrapper.dart';
import 'friends_screen.dart';
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

  runApp(const MaterialApp(home: AuthWrapper()));
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

class HangApp extends StatefulWidget {
  const HangApp({super.key});
  @override
  State<HangApp> createState() => _HangAppState();
}

class _HangAppState extends State<HangApp> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const _RadarTab(),
    const FriendsScreen(),
    const SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        backgroundColor: Colors.black,
        selectedItemColor: const Color(0xFFFF8800),
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.radar), label: 'Radar'),
          BottomNavigationBarItem(icon: Icon(Icons.people), label: 'Friends'),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class _RadarTab extends StatefulWidget {
  const _RadarTab();
  @override
  State<_RadarTab> createState() => _RadarTabState();
}

class _RadarTabState extends State<_RadarTab> {
  H3? h3;
  H3Index? currentH3Index;
  List<H3Index>? currentKRing;
  String sectorText = '';
  String statusText = 'Waiting for location...';
  bool supabaseAvailable = false;
  String supabaseRawResponse = '';
  List<Map<String, dynamic>> nearbyFriends = [];
  bool _isIncognito = false;
  DateTime? _incognitoUntil;
  bool _isInSafeZone = false;

  bool get hasNearbyFriends => nearbyFriends.isNotEmpty;

  @override
  void initState() {
    super.initState();
    try {
      h3 = const H3Factory().load();
      debugPrint('[h3_ffi] H3 native library initialized');
    } catch (e) {
      debugPrint('[h3_ffi] Failed to initialize H3 native library: $e');
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

    _testSupabaseConnection();
    _loadIncognitoStatus();
    _loadSafeZoneStatus();
  }

  @override
  void dispose() {
    super.dispose();
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

  Future<void> _loadSafeZoneStatus() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final resp = await Supabase.instance.client
          .from('profiles')
          .select('is_in_safe_zone')
          .eq('id', userId)
          .single();

      if (mounted) {
        setState(() {
          _isInSafeZone = resp['is_in_safe_zone'] ?? false;

          // Clear nearby friends when in safe zone
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

  String _getAgeLabel(String? updatedAtStr) {
    if (updatedAtStr == null) return '?';

    try {
      final updatedAt = DateTime.parse(updatedAtStr);
      final age = DateTime.now().difference(updatedAt);

      if (age.inMinutes < 10) {
        return '<10min';
      } else if (age.inMinutes < 30) {
        return '<30min';
      } else if (age.inHours < 1) {
        return '<1h';
      } else if (age.inHours < 2) {
        return '<2h';
      } else if (age.inHours < 24) {
        return '>${age.inHours}h';
      } else {
        return '>${age.inDays}d';
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
        desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
        distanceFilter: 150.0,
        stopOnTerminate: false,
        startOnBoot: true,
        debug: true,
        logLevel: bg.Config.LOG_LEVEL_VERBOSE,
        locationAuthorizationRequest: 'Always',
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

    // Get current position immediately (especially important for simulator)
    try {
      final location = await bg.BackgroundGeolocation.getCurrentPosition();
      _onLocation(location);
    } catch (e) {
      debugPrint('[location] Failed to get current position: $e');
      // Not critical, will wait for location updates
    }
  }

  Future<void> _testSupabaseConnection() async {
    // Test if Supabase is available and working
    try {
      final testResp = await Supabase.instance.client
          .from('profiles')
          .select('handle')
          .limit(1)
          .timeout(const Duration(seconds: 8));

      debugPrint('[supabase] Connection test successful: $testResp');

      if (!mounted) return;
      setState(() {
        supabaseAvailable = true;
      });

      // If we already have a location, check for friends now
      if (currentKRing != null) {
        debugPrint('[supabase] Re-checking friends with existing location');
        _checkFriendsInKRing(currentKRing!);
      }
    } catch (e) {
      debugPrint('[supabase] Connection test failed: $e');
      if (!mounted) return;
      setState(() {
        supabaseAvailable = false;
        supabaseRawResponse = 'Supabase-Verbindung fehlgeschlagen: $e';
      });
    }
  }

  void _onLocation(bg.Location location) {
    final lat = location.coords.latitude;
    final lng = location.coords.longitude;
    if (h3 == null) {
      debugPrint('[h3_ffi] H3 not available on location update');
      if (mounted) {
        setState(() {
          statusText = 'H3 not loaded; location not processed.';
        });
      }
      return;
    }

    H3Index cell;
    List<H3Index> kRingCells;
    try {
      cell = h3!.geoToCell(GeoCoord(lat: lat, lon: lng), 9);
      kRingCells = h3!.gridDisk(cell, 2);
    } catch (e) {
      debugPrint('[h3_ffi] Error converting location to H3: $e');
      if (mounted) {
        setState(() {
          statusText = 'Error in H3 calculation.';
        });
      }
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

    // Update user's location in Supabase
    _updateUserLocation(cell);

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

      // Check if user is in a safe zone
      // Safe zones can contain multiple H3 indices (comma-separated)
      final safeZones = await Supabase.instance.client
          .from('safe_zones')
          .select('h3_index_res9')
          .eq('user_id', user.id);

      bool isInSafeZone = false;
      for (final zone in safeZones) {
        final h3Indices = (zone['h3_index_res9'] as String).split(',');
        if (h3Indices.contains(hexIndex)) {
          isInSafeZone = true;
          break;
        }
      }

      debugPrint(
        '[location] Updating location: $hexIndex, in safe zone: $isInSafeZone',
      );

      await Supabase.instance.client
          .from('profiles')
          .update({
            'last_h3_index_res9': hexIndex,
            'is_in_safe_zone': isInSafeZone,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', user.id);
    } catch (e) {
      debugPrint('[location] Failed to update user location: $e');
    }
  }

  void _onLocationError(bg.LocationError error) {
    debugPrint('[location error] - $error');
    if (mounted) {
      setState(() {
        statusText = 'Location-Fehler: ${error.message}';
      });
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
        statusText = 'Supabase not configured; no friends shown.';
      });
    }
  }

  Future<void> _checkFriendsInKRingFromSupabase(
    List<H3Index> kRingCells,
  ) async {
    // Reload incognito and safe zone status before checking friends
    await _loadIncognitoStatus();
    await _loadSafeZoneStatus();

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

      // Query profiles that are friends AND in the kRing AND NOT in safe zone
      final resp = await Supabase.instance.client
          .from('profiles')
          .select(
            'handle,last_h3_index_res9,id,updated_at,is_in_safe_zone,is_incognito,incognito_until',
          )
          .inFilter('last_h3_index_res9', hexesRes9)
          .inFilter('id', friendIds.toList())
          .eq('is_in_safe_zone', false)
          .timeout(const Duration(seconds: 15));

      // Filter out incognito users client-side (check expiration)
      final now = DateTime.now().toUtc();
      final visibleFriends = resp.where((friend) {
        final isIncognito = friend['is_incognito'] ?? false;
        if (!isIncognito) return true;

        final untilStr = friend['incognito_until'];
        if (untilStr == null) return false; // Indefinite incognito

        final until = DateTime.parse(untilStr);
        return now.isAfter(until); // Only show if incognito expired
      }).toList();

      debugPrint(
        '[supabase] Found ${visibleFriends.length}/${resp.length} visible friends',
      );
      if (!mounted) return;

      setState(() {
        supabaseRawResponse = visibleFriends.toString();
      });

      if (visibleFriends.isEmpty) {
        if (!mounted) return;
        setState(() {
          nearbyFriends = [];
          statusText = 'No friends in kRing yet.';
        });
        return;
      }

      final friends = <Map<String, dynamic>>[];
      for (final row in visibleFriends) {
        final map = Map<String, dynamic>.from(row as Map);
        final handle = map['handle'] as String?;
        final updatedAt = map['updated_at'] as String?;
        if (handle != null) {
          friends.add({'handle': handle, 'updated_at': updatedAt});
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

  void _refreshSector() {
    if (h3 == null) {
      if (mounted) {
        setState(() {
          statusText = 'H3 not available — cannot calculate sector.';
        });
      }
      return;
    }

    if (currentH3Index == null) {
      if (mounted) {
        setState(() {
          statusText = 'No location available.';
        });
      }
      return;
    }

    try {
      final kRingCells = h3!.gridDisk(currentH3Index!, 2);
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

  void _setTestLocation() {
    // Test location: Berlin, Germany
    const testLat = 52.5200;
    const testLng = 13.4050;

    debugPrint('[test] Setting test location: $testLat, $testLng');

    if (h3 == null) {
      debugPrint('[test] H3 not available');
      return;
    }

    try {
      final cell = h3!.geoToCell(GeoCoord(lat: testLat, lon: testLng), 9);
      final kRingCells = h3!.gridDisk(cell, 2);

      if (mounted) {
        setState(() {
          currentH3Index = cell;
          currentKRing = kRingCells;
          sectorText = cell.toRadixString(16);
          statusText = 'Test location: Berlin';
        });
      }

      // Update user's location in Supabase
      _updateUserLocation(cell);

      _checkFriendsInKRing(kRingCells);
    } catch (e) {
      debugPrint('[test] Error setting test location: $e');
    }
  }

  void _showSectorBanner(String sector) {
    final overlay = Overlay.of(context);
    if (overlay == null) return;

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
      backgroundColor: Colors.black,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
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
                                color: Color(0xFF4DD0E1).withOpacity(0.7),
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
                    color: Colors.deepPurple.withOpacity(0.2),
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
                        child: CustomPaint(
                          painter: HexagonGridPainter(
                            hasNearbyFriends: hasNearbyFriends,
                            isIncognito: _isIncognito,
                            isInSafeZone: _isInSafeZone,
                          ),
                        ),
                      ),
                      // Glow wave on top (BlendMode.plus adds light without covering)
                      if (!_isIncognito && !_isInSafeZone)
                        SizedBox.expand(
                          child: GlowWaveOverlay(
                            isActive: hasNearbyFriends,
                            color: const Color(0xFFFF8800),
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
                      ? const Color(0xFFFF8A00)
                      : Colors.white70,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
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
              if (!_isIncognito && !_isInSafeZone) ...[
                if (nearbyFriends.isNotEmpty) ...[
                  const Text(
                    'Friends nearby',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...nearbyFriends.map((friend) {
                    final handle = friend['handle'] as String;
                    final updatedAt = friend['updated_at'] as String?;
                    final ageLabel = _getAgeLabel(updatedAt);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '@$handle ($ageLabel)',
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }),
                ] else ...[
                  const Text(
                    'No friends nearby.',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
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

  HexagonGridPainter({
    required this.hasNearbyFriends,
    this.isIncognito = false,
    this.isInSafeZone = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final side = min(size.width, size.height) * 0.085;
    final spacingX = side * sqrt(3);
    final spacingY = side * 1.5;
    final cells = <Offset>[];

    for (var q = -2; q <= 2; q++) {
      for (var r = max(-2, -q - 2); r <= min(2, -q + 2); r++) {
        final x = (q + r / 2) * spacingX;
        final y = r * spacingY;
        cells.add(center + Offset(x, y));
      }
    }

    for (var i = 0; i < cells.length; i++) {
      final cellCenter = cells[i];
      final isCore = i == 9; // center cell
      Color fillColor;
      Color borderColor;
      if (isCore) {
        if (isIncognito) {
          // Lila für Inkognito
          fillColor = const Color(0xFF2D1B3D);
          borderColor = Colors.deepPurple;
        } else if (isInSafeZone) {
          // Cyan/Mint für Safe Zone
          fillColor = const Color(0xFF1A3A3D);
          borderColor = const Color(0xFF4DD0E1);
        } else {
          fillColor = hasNearbyFriends
              ? const Color(0xFFFF8A00)
              : const Color(0xFF311B00);
          borderColor = hasNearbyFriends
              ? const Color(0xFFFF8A00)
              : Colors.white70;
        }
      } else {
        fillColor = const Color(0xFF111111);
        borderColor = Colors.white10;
      }
      final fill = Paint()..color = fillColor;
      canvas.drawPath(_hexagonPath(cellCenter, side), fill);

      final border = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isCore ? 4 : 2
        ..color = borderColor;
      canvas.drawPath(_hexagonPath(cellCenter, side), border);
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
        oldDelegate.isInSafeZone != isInSafeZone;
  }
}
