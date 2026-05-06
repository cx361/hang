import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_apns_only/flutter_apns_only.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// In debug builds use a short cooldown so testing is easy.
const _kCooldown = kDebugMode ? Duration(minutes: 1) : Duration(hours: 3);

/// Handles symmetric proximity notifications between two users.
///
/// When User A detects User B nearby:
///   1. We check the `proximity_pings` table for a cooldown on the pair.
///   2. If no cooldown: upsert the ping (including triggered_by_user_id) and
///      notify User A immediately via a local notification.
///   3. A Supabase Edge Function (push-proximity-ping) triggered by the DB
///      INSERT sends an APNs push to User B's device — this works even when
///      User B's app is completely terminated.
///   4. If the cooldown is still active: silently skip.
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
    // Request permission and start listening for the device token.
    _apnsConnector!.requestNotificationPermissions();
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
    try {
      await Supabase.instance.client
          .from('profiles')
          .update({'apns_token': token})
          .eq('id', userId);
      _log('[proximity] APNs token saved to profiles');
    } catch (e) {
      _log('[proximity] Error saving APNs token: $e');
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
    final record = payload.newRecord;
    final pairKey = record['pair_key'] as String?;
    if (pairKey == null) return;

    // Self-triggered pings: the sender already showed a local notification
    // in _tryPing — skip to avoid a duplicate.
    if (_selfTriggered.remove(pairKey)) return;

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
        // Edge Function reads this to know who triggered the ping and pushes
        // only the *other* user via APNs.
        'triggered_by_user_id': currentUserId,
      }, onConflict: 'pair_key');

      _log('[proximity] Pinged pair $pairKey');

      // Notify the local user immediately.
      // The friend is notified via APNs (Supabase Edge Function).
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
