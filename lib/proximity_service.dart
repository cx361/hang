import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// In debug builds use a short cooldown so testing is easy.
const _kCooldown = kDebugMode ? Duration(minutes: 1) : Duration(hours: 3);

/// Handles symmetric proximity notifications between two users.
///
/// When User A detects User B nearby:
///   1. We check the `proximity_pings` table for a cooldown (5 h) on the pair.
///   2. If no cooldown: upsert the ping, notify User A immediately, and let
///      Supabase Realtime deliver the event so User B is also notified.
///   3. If the cooldown is still active: silently skip.
///
/// Because the pair_key is canonical (min UID : max UID), even if both clients
/// run the check simultaneously the database serialises them — only one INSERT
/// fires, and both users receive exactly one notification.
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

  final _notifications = FlutterLocalNotificationsPlugin();

  RealtimeChannel? _channelA;
  RealtimeChannel? _channelB;
  bool _initialized = false;
  int _notifId = 0;

  // pair_keys that this client just upserted — used to suppress the echo
  // notification that arrives via Realtime for the local user.
  final _selfTriggered = <String>{};

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
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDescription,
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
  }

  void _onEvent(PostgresChangePayload payload, String currentUserId) {
    final record = payload.newRecord;
    final pairKey = record['pair_key'] as String?;
    if (pairKey == null) return;

    // If this client triggered the ping it already showed a notification —
    // remove from set and skip to avoid a duplicate.
    if (_selfTriggered.remove(pairKey)) return;

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
    const android = AndroidNotificationDetails(
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
    const details = NotificationDetails(
      android: android,
      iOS: apple,
      macOS: apple,
    );

    final id = _notifId++ & 0x7FFFFFFF;
    await _notifications.show(id, 'hang.', '$handle is nearby! 👋', details);
    _log('[proximity] Notification shown for $handle');
  }

  // ── Ping logic ────────────────────────────────────────────────────────────

  /// Call this after detecting nearby friends.
  /// [nearbyFriends] must contain maps with at least `'id'` and `'handle'`.
  Future<void> checkAndPing(List<Map<String, dynamic>> nearbyFriends) async {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null) return;

    for (final friend in nearbyFriends) {
      final friendId = friend['id'] as String?;
      if (friendId == null) continue;
      final handle = (friend['handle'] as String?) ?? 'Jemand';
      await _tryPing(currentUserId, friendId, handle);
    }
  }

  Future<void> _tryPing(
    String currentUserId,
    String friendId,
    String handle,
  ) async {
    // Canonical pair_key — smaller UUID first so both clients produce the same key.
    final a = currentUserId.compareTo(friendId) <= 0 ? currentUserId : friendId;
    final b = currentUserId.compareTo(friendId) <= 0 ? friendId : currentUserId;
    final pairKey = '$a:$b';

    final cooldownCutoff = DateTime.now()
        .toUtc()
        .subtract(_kCooldown)
        .toIso8601String();

    try {
      // Check whether the cooldown is still active for this pair.
      final existing = await Supabase.instance.client
          .from('proximity_pings')
          .select('pinged_at')
          .eq('pair_key', pairKey)
          .gte('pinged_at', cooldownCutoff)
          .maybeSingle();

      if (existing != null) {
        _log(
          '[proximity] Cooldown for $pairKey '
          '(last: ${existing['pinged_at']})',
        );
        return;
      }

      // Register as self-triggered BEFORE the upsert so the Realtime echo
      // that arrives on this device is suppressed.
      _selfTriggered.add(pairKey);

      await Supabase.instance.client.from('proximity_pings').upsert({
        'pair_key': pairKey,
        'user_a_id': a,
        'user_b_id': b,
        'pinged_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'pair_key');

      _log('[proximity] Pinged pair $pairKey');

      // Notify the local user immediately (the friend is notified via Realtime).
      await _showNotification(handle);
    } catch (e) {
      _selfTriggered.remove(pairKey);
      _log('[proximity] Error pinging $pairKey: $e');
    }
  }

  // ── Cleanup ───────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await _channelA?.unsubscribe();
    await _channelB?.unsubscribe();
    _channelA = null;
    _channelB = null;
    _initialized = false;
  }
}
