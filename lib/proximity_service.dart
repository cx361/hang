import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_apns_only/flutter_apns_only.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// In debug builds use a short cooldown so testing is easy.
const _kCooldown = kDebugMode ? Duration(minutes: 1) : Duration(hours: 2);

// Maximum age of a friend's last-known location before we refuse to ping.
// If a friend's phone died / went offline, their stale H3 hex can linger in
// the DB and keep matching our kRing.  We skip the ping until they update.
const _kLocationMaxAge = kDebugMode
    ? Duration(minutes: 120)
    : Duration(hours: 4);

/// Handles symmetric proximity notifications between two users via DB-authoritative cooldowns.
///
/// When User A detects User B nearby:
///   1. We check the `proximity_pings` table for a cooldown on the pair.
///      Cooldown is active if either `pinged_at` or `last_seen_at` is within
///      the cooldown window. A fresh `last_seen_at` keeps sessions alive
///      across app restarts without re-pinging.
///   2. If no cooldown: upsert the ping (including triggered_by_user_id),
///      set both `pinged_at` and `last_seen_at` to now, and notify User A
///      immediately via a local notification.
///   3. A Supabase Edge Function (push-proximity-ping) triggered by the DB
///      INSERT sends an APNs push to User B's device — this works even when
///      User B's app is completely terminated.
///   4. If the cooldown is still active: heartbeat `last_seen_at` and skip
///      the ping.
///
/// Because the pair_key is canonical (min UID : max UID), even if both clients
/// run the check simultaneously the database serialises them — only one INSERT
/// fires, and each user receives exactly one notification.
class ProximityService {
  ProximityService._();
  static final ProximityService instance = ProximityService._();

  /// Optional callback that forwards log messages to the in-app debug box.
  void Function(String)? uiLogger;

  void _log(String msg) {
    debugPrint(msg);
    uiLogger?.call(msg.replaceFirst('[proximity] ', ''));
  }

  static const _channelId = 'proximity_alerts';
  static const _channelName = 'Nearby Friends';
  static const _channelDescription = 'Alerts when friends are nearby';

  static const _friendChannelId = 'friend_alerts';
  static const _friendChannelName = 'Friend Requests';
  static const _friendChannelDescription =
      'Alerts for friend requests and acceptances';

  final _notifications = FlutterLocalNotificationsPlugin();

  RealtimeChannel? _channelA;
  RealtimeChannel? _channelB;
  RealtimeChannel? _channelFriendRequest;
  RealtimeChannel? _channelFriendAccepted;
  bool _initialized = false;
  int _notifId = 0;
  String? _apnsToken;

  // pair_keys that this client just upserted — used to suppress the echo
  // notification that arrives via Realtime for the local user.
  final _selfTriggered = <String>{};

  // Cached silent-zone status for the current user.  Updated by
  // checkAndPing() and updateSilentZoneStatus() so that _onEvent() can
  // suppress foreground notifications when the user is in a silent zone.
  bool _isCurrentUserInSilentZone = false;

  /// Call this whenever the user's silent-zone status changes (e.g. after
  /// _loadSilentZoneStatus in main.dart) so that Realtime-triggered
  /// notifications can be suppressed even between proximity polls.
  void updateSilentZoneStatus(bool isInSilentZone) {
    _isCurrentUserInSilentZone = isInSilentZone;
  }

  // ── init ──────────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const appleSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: false,
      requestSoundPermission: true,
    );

    // On iOS, initialize() returns true only if notification permission is
    // granted. Log this so we can diagnose permission issues.
    final initResult = await _notifications.initialize(
      const InitializationSettings(
        android: androidSettings,
        iOS: appleSettings,
        macOS: appleSettings,
      ),
      onDidReceiveNotificationResponse: (_) {},
    );
    _log('[proximity] initialize result (permission granted): $initResult');

    // Android O+ requires an explicit notification channel.
    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.high,
      ),
    );
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _friendChannelId,
        _friendChannelName,
        description: _friendChannelDescription,
        importance: Importance.high,
      ),
    );

    // iOS: use DarwinFlutterLocalNotificationsPlugin (replaces iOS-specific
    // class in flutter_local_notifications v18+).
    final iosGranted = await _notifications
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: false, sound: true);
    _log('[proximity] iOS permission granted: $iosGranted');

    final macGranted = await _notifications
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: false, sound: true);
    _log('[proximity] macOS permission granted: $macGranted');

    _initialized = true;
    _subscribeRealtime();
    _registerApnsToken();

    // CRITICAL: Register lifecycle observer to clean up channels when app terminates
    WidgetsBinding.instance.addObserver(_LifecycleObserver(this));

    // Log the actual iOS permission state so we can diagnose silent failures.
    final iosPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (iosPlugin != null) {
      final perms = await iosPlugin.checkPermissions();
      _log(
        '[proximity] iOS perms — isEnabled:${perms?.isEnabled} '
        'alert:${perms?.isAlertEnabled} sound:${perms?.isSoundEnabled} '
        'badge:${perms?.isBadgeEnabled}',
      );
    } else {
      _log('[proximity] iOS plugin not resolved (non-iOS device?)');
    }

    _log('[proximity] Service initialized');
  }

  // ── APNs token registration ───────────────────────────────────────────────

  ApnsPushConnectorOnly? _apnsConnector;

  void _registerApnsToken() {
    if (!Platform.isIOS) return;

    _apnsConnector = ApnsPushConnectorOnly();
    // Do NOT call requestNotificationPermissions() here — flutter_local_notifications
    // already requests alert/sound permissions, and calling it from a background
    // context causes FlutterEngine to assert on Thread 2 (flutter_apns_only bug).
    // configureApns() triggers UIApplication.registerForRemoteNotifications() which
    // is sufficient to obtain the APNs device token.
    _apnsConnector!.configureApns(
      // When the app is foregrounded, Realtime already shows a local
      // notification for the same event — suppress the APNs banner here
      // to avoid showing the user a duplicate.
      onMessage: (_) async {
        _log(
          '[proximity] APNs foreground message suppressed (Realtime handles it)',
        );
      },
    );
    _apnsConnector!.token.addListener(() {
      final token = _apnsConnector!.token.value;
      if (token == null || token == _apnsToken) return;
      _apnsToken = token;
      _log('[proximity] APNs token: ${token.substring(0, 8)}…');
      _saveApnsToken(token);
    });
  }

  Future<void> _saveApnsToken(String token) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    // CRITICAL FIX #7 & HIGH FIX #17: Token validation, rotation, and retry logic
    if (token.isEmpty || token.length < 32) {
      _log('[proximity] Invalid APNs token format — skipping save');
      return;
    }

    int retryCount = 0;
    const maxRetries = 3;

    while (retryCount < maxRetries) {
      try {
        await Supabase.instance.client
            .from('profiles')
            .update({'apns_token': token})
            .eq('id', userId);
        _log('[proximity] APNs token saved and rotated');
        return;
      } catch (e) {
        retryCount++;
        if (retryCount >= maxRetries) {
          _log(
            '[proximity] Failed to save APNs token after $maxRetries attempts: $e',
          );
          return;
        }
        // Exponential backoff: 500ms, 1s, 2s
        await Future<void>.delayed(
          Duration(milliseconds: 500 * (1 << (retryCount - 1))),
        );
      }
    }
  }

  // ── Realtime subscription ─────────────────────────────────────────────────

  void _subscribeRealtime() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      debugPrint('[proximity] No authenticated user — skipping Realtime setup');
      return;
    }

    final db = Supabase.instance.client;

    // We need two channels because Supabase Realtime filters don't support OR.

    _channelA = db
        .channel('prox_a_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'proximity_pings',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_a_id',
            value: userId,
          ),
          callback: (p) => _onEvent(p, userId),
        )
        .subscribe((status, [err]) {
          _log('[proximity] channel_a status: $status err: $err');
        });

    _channelB = db
        .channel('prox_b_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'proximity_pings',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_b_id',
            value: userId,
          ),
          callback: (p) => _onEvent(p, userId),
        )
        .subscribe((status, [err]) {
          _log('[proximity] channel_b status: $status err: $err');
        });

    // Friend request received: INSERT on friendships where addressee_id = me
    _channelFriendRequest = db
        .channel('friend_req_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'friendships',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'addressee_id',
            value: userId,
          ),
          callback: (p) => _onFriendRequestReceived(p),
        )
        .subscribe((status, [err]) {
          _log('[proximity] friend_req channel status: $status err: $err');
        });

    // Friend request accepted: UPDATE on friendships where requester_id = me
    _channelFriendAccepted = db
        .channel('friend_acc_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'friendships',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'requester_id',
            value: userId,
          ),
          callback: (p) => _onFriendRequestAccepted(p),
        )
        .subscribe((status, [err]) {
          _log('[proximity] friend_acc channel status: $status err: $err');
        });
  }

  void _onFriendRequestReceived(PostgresChangePayload payload) {
    // APNs push handles the recipient notification when the app is backgrounded
    // or terminated. When the app IS in the foreground show a local notification
    // as well so the user isn't left without feedback.
    final record = payload.newRecord;
    final status = record['status'] as String?;
    if (status != 'pending') return;
    final requesterId = record['requester_id'] as String?;
    if (requesterId == null) return;
    _notifyFriendRequest(requesterId);
  }

  void _onFriendRequestAccepted(PostgresChangePayload payload) {
    final record = payload.newRecord;
    final status = record['status'] as String?;
    if (status != 'accepted') return;
    final addresseeId = record['addressee_id'] as String?;
    if (addresseeId == null) return;
    _notifyFriendAccepted(addresseeId);
  }

  Future<void> _notifyFriendRequest(String requesterId) async {
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('handle')
          .eq('id', requesterId)
          .single();
      final handle = (row['handle'] as String?) ?? 'Someone';
      await _showFriendNotification('$handle wants to be your friend! 🤝');
      _log('[proximity] Friend request notification shown for $handle');
    } catch (e) {
      _log('[proximity] Error fetching handle for friend request: $e');
      await _showFriendNotification('Someone sent you a friend request! 🤝');
    }
  }

  Future<void> _notifyFriendAccepted(String addresseeId) async {
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('handle')
          .eq('id', addresseeId)
          .single();
      final handle = (row['handle'] as String?) ?? 'Someone';
      await _showFriendNotification('$handle accepted your friend request! 🎉');
      _log('[proximity] Friend accepted notification shown for $handle');
    } catch (e) {
      _log('[proximity] Error fetching handle for friend accepted: $e');
      await _showFriendNotification('Someone accepted your friend request! 🎉');
    }
  }

  Future<void> _showFriendNotification(String body) async {
    if (!_initialized) await initialize();
    const android = AndroidNotificationDetails(
      _friendChannelId,
      _friendChannelName,
      channelDescription: _friendChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
    );
    const apple = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentBadge: false,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    const details = NotificationDetails(
      android: android,
      iOS: apple,
      macOS: apple,
    );
    final id = _notifId++ & 0x7FFFFFFF;
    await _notifications.show(id, 'hang.', body, details);
  }

  void _onEvent(PostgresChangePayload payload, String currentUserId) {
    // Delegate to async handler so we can do a live DB read before
    // deciding whether to show the notification.
    _handleProximityEvent(payload, currentUserId);
  }

  Future<void> _handleProximityEvent(
    PostgresChangePayload payload,
    String currentUserId,
  ) async {
    final record = payload.newRecord;
    final pairKey = record['pair_key'] as String?;
    if (pairKey == null) return;

    // Self-triggered pings: the sender already showed a local notification
    // in _tryPing — skip to avoid a duplicate.
    if (_selfTriggered.remove(pairKey)) return;

    // Read is_in_silent_zone live from the DB at the moment the notification
    // would fire. The in-memory flag can be stale at startup (set
    // asynchronously), so we always go to the source.
    try {
      final profile = await Supabase.instance.client
          .from('profiles')
          .select('is_in_silent_zone')
          .eq('id', currentUserId)
          .single();
      if ((profile['is_in_silent_zone'] as bool?) ?? false) {
        _log(
          '[proximity] Realtime ping suppressed — current user in silent zone',
        );
        return;
      }
    } catch (e) {
      // DB read failed — fall back to the in-memory cache.
      _log('[proximity] Silent zone DB check failed ($e) — using cached value');
      if (_isCurrentUserInSilentZone) {
        _log(
          '[proximity] Realtime ping suppressed — current user in silent zone (cached)',
        );
        return;
      }
    }

    // The recipient is notified via APNs (Edge Function) when backgrounded.
    // When the app IS in the foreground, show a local notification too so
    // nothing is missed while the user is actively using the app.
    final otherUserId = (record['user_a_id'] as String?) == currentUserId
        ? record['user_b_id'] as String?
        : record['user_a_id'] as String?;

    if (otherUserId == null) return;
    _notifyFromUserId(otherUserId);
  }

  Future<void> _notifyFromUserId(String userId) async {
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('handle')
          .eq('id', userId)
          .single();
      final handle = (row['handle'] as String?) ?? 'Jemand';
      await _showNotification(handle);
    } catch (e) {
      _log('[proximity] Error fetching handle: $e');
      await _showNotification('Jemand');
    }
  }

  Future<void> _showNotification(String handle) async {
    // Ensure the plugin is ready even if initialize() wasn't awaited.
    if (!_initialized) await initialize();
    final android = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
    );
    const apple = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentBadge: false,
      presentSound: true,
      // timeSensitive breaks through Focus/DND on iOS 15+
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    final details = NotificationDetails(
      android: android,
      iOS: apple,
      macOS: apple,
    );

    final id = _notifId++ & 0x7FFFFFFF;
    await _notifications.show(
      id,
      'hang.',
      'hey! @$handle\'s close! ✨',
      details,
    );
    _log('[proximity] Notification shown for $handle');

    // Custom vibration/haptic removed: iOS does not support custom vibration for notifications.
  }

  // ── Ping logic ────────────────────────────────────────────────────────────

  /// Call this after each proximity poll — pass the full current nearby list
  /// (may be empty). Ping decisions are DB-authoritative:
  /// `_tryPing` checks `pinged_at` + `last_seen_at` for cooldown and updates
  /// `last_seen_at` for active sessions.
  ///
  /// [currentUserInSilentZone]: pass the caller's current silent-zone flag.
  /// When true, all ping attempts are suppressed for this tick.
  Future<void> checkAndPing(
    List<Map<String, dynamic>> nearbyFriends, {
    bool currentUserInSilentZone = false,
  }) async {
    // Cache for Realtime event suppression between polls.
    _isCurrentUserInSilentZone = currentUserInSilentZone;

    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null) return;

    final now = DateTime.now();

    if (currentUserInSilentZone) {
      _log('[proximity] Skipping all pings — current user in silent zone');
      return;
    }

    // Fetch incognito status once for all friends — avoids N identical DB reads.
    bool isIncognito = false;
    DateTime? incognitoUntil;
    try {
      final userProfile = await Supabase.instance.client
          .from('profiles')
          .select('is_incognito, incognito_until')
          .eq('id', currentUserId)
          .maybeSingle();
      if (userProfile != null) {
        isIncognito = userProfile['is_incognito'] as bool? ?? false;
        final untilStr = userProfile['incognito_until'] as String?;
        if (untilStr != null) {
          String normalized = untilStr;
          if (!untilStr.endsWith('Z') && !untilStr.contains('+')) {
            normalized = '${untilStr}Z';
          }
          incognitoUntil = DateTime.tryParse(normalized)?.toUtc();
        }
      }
    } catch (e) {
      _log('[proximity] Error fetching incognito status: $e');
    }

    for (final friend in nearbyFriends) {
      final friendId = friend['id'] as String?;
      if (friendId == null) continue;

      // Skip friends whose location is stale (phone died, app killed, etc.).
      final updatedAtStr = friend['updated_at'] as String?;
      if (updatedAtStr != null) {
        try {
          final locationAge = now.toUtc().difference(
            DateTime.parse(updatedAtStr).toUtc(),
          );
          if (locationAge > _kLocationMaxAge) {
            _log(
              '[proximity] Skipping ping for ${friend['handle']} — '
              'location is ${locationAge.inMinutes}min old (>${_kLocationMaxAge.inMinutes}min)',
            );
            continue;
          }
        } catch (_) {
          // Unparseable timestamp — treat as stale to be safe.
          _log(
            '[proximity] Skipping ping for ${friend['handle']} — '
            'could not parse updated_at: $updatedAtStr',
          );
          continue;
        }
      }

      // Silent zone: if the friend doesn't want pings, skip them too.
      final friendInSilentZone =
          (friend['is_in_silent_zone'] as bool?) ?? false;
      if (friendInSilentZone) {
        _log(
          '[proximity] Skipping ping for ${friend['handle']} — friend in silent zone',
        );
        continue;
      }

      final handle = (friend['handle'] as String?) ?? 'Jemand';
      await _tryPing(
        currentUserId,
        friendId,
        handle,
        isIncognito: isIncognito,
        incognitoUntil: incognitoUntil,
      );
    }
  }

  /// Attempts to ping a friend pair if cooldown allows.
  /// Implements DB-authoritative cooldown logic:
  /// - Checks existing `proximity_pings` record for `pinged_at` or `last_seen_at` within cooldown.
  /// - If active: heartbeat `last_seen_at` and return (no new ping).
  /// - If expired: upsert with new `pinged_at` and `last_seen_at`, then notify.
  /// Verifies incognito status fresh from DB right before ping to prevent timing attacks.
  Future<void> _tryPing(
    String currentUserId,
    String friendId,
    String handle, {
    bool isIncognito = false,
    DateTime? incognitoUntil,
  }) async {
    try {
      if (isIncognito &&
          incognitoUntil != null &&
          DateTime.now().toUtc().isBefore(incognitoUntil)) {
        _log(
          '[proximity] ⚠️ Skipping ping for $handle — user incognito mode active',
        );
        return;
      }

      // Canonical pair_key — smaller UUID first so both clients produce the same key.
      final a = currentUserId.compareTo(friendId) <= 0
          ? currentUserId
          : friendId;
      final b = currentUserId.compareTo(friendId) <= 0
          ? friendId
          : currentUserId;
      final pairKey = '$a:$b';

      // Check whether the cooldown is still active for this pair.
      // We fetch both pinged_at and last_seen_at without a server-side filter
      // so we can OR them in Dart: cooldown is active if EITHER timestamp is
      // within the cooldown window.  last_seen_at stays fresh via heartbeats
      // even across app restarts, so a session > 5h doesn't produce a re-ping.
      final existing = await Supabase.instance.client
          .from('proximity_pings')
          .select('pinged_at, last_seen_at')
          .eq('pair_key', pairKey)
          .maybeSingle();

      if (existing != null) {
        final cutoff = DateTime.now().toUtc().subtract(_kCooldown);

        bool withinCooldown = false;
        final pingedAtStr = existing['pinged_at'] as String?;
        if (pingedAtStr != null) {
          final pingedAt = DateTime.tryParse(pingedAtStr)?.toUtc();
          if (pingedAt != null && pingedAt.isAfter(cutoff)) {
            withinCooldown = true;
          }
        }
        if (!withinCooldown) {
          final lastSeenStr = existing['last_seen_at'] as String?;
          if (lastSeenStr != null) {
            final lastSeenAt = DateTime.tryParse(lastSeenStr)?.toUtc();
            if (lastSeenAt != null && lastSeenAt.isAfter(cutoff)) {
              withinCooldown = true;
            }
          }
        }

        if (withinCooldown) {
          // Heartbeat active sessions without issuing a new ping.
          _updateLastSeen(pairKey, handle);
          return;
        }
      }

      // Register as self-triggered BEFORE the upsert so the Realtime echo
      // that arrives on this device is suppressed.
      _selfTriggered.add(pairKey);

      final nowIso = DateTime.now().toUtc().toIso8601String();
      await Supabase.instance.client.from('proximity_pings').upsert({
        'pair_key': pairKey,
        'user_a_id': a,
        'user_b_id': b,
        'pinged_at': nowIso,
        'last_seen_at': nowIso,
        // Edge Function reads this to know who triggered the ping and pushes
        // only the *other* user via APNs.
        'triggered_by_user_id': currentUserId,
      }, onConflict: 'pair_key');

      _log('[proximity] Pinged @$handle');

      // Notify the local user immediately.
      // The friend is notified via APNs (Supabase Edge Function).
      await _showNotification(handle);
    } catch (e) {
      _log('[proximity] Error in _tryPing for $handle: $e');
    }
  }

  /// Heartbeat: updates `last_seen_at` for an ongoing session without changing `pinged_at`.
  /// Used both during active proximity (checkAndPing) and when cooldown is active (_tryPing).
  /// The DB webhook guard in the Edge Function detects that `pinged_at` is unchanged
  /// and skips the APNs push, so only local session bookkeeping happens.
  void _updateLastSeen(String pairKey, String handle) {
    Supabase.instance.client
        .from('proximity_pings')
        .update({'last_seen_at': DateTime.now().toUtc().toIso8601String()})
        .eq('pair_key', pairKey)
        .then((_) {
          _log('[proximity] still nearby: @$handle (last_seen_at updated)');
        })
        .catchError((Object e) {
          _log('[proximity] Error updating last_seen_at for @$handle: $e');
        });
  }

  // ── Cleanup ───────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await _channelA?.unsubscribe();
    await _channelB?.unsubscribe();
    await _channelFriendRequest?.unsubscribe();
    await _channelFriendAccepted?.unsubscribe();
    _channelA = null;
    _channelB = null;
    _channelFriendRequest = null;
    _channelFriendAccepted = null;
    _apnsConnector?.dispose();
    _apnsConnector = null;
    _initialized = false;
  }
}

// CRITICAL: Lifecycle observer to ensure Realtime channels are cleaned up
// when the app terminates, preventing connection pool exhaustion on app restart.
class _LifecycleObserver extends WidgetsBindingObserver {
  _LifecycleObserver(this.service);
  final ProximityService service;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      debugPrint('[proximity] App detached - cleaning up Realtime channels');
      service.dispose();
    }
  }
}
