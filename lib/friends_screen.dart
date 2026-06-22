import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'profile_screen.dart';
import 'validation_helpers.dart';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen>
    with SingleTickerProviderStateMixin {
  static const MethodChannel _contactsChannel = MethodChannel('hang/contacts');

  late final TabController _tabController;
  final _searchController = TextEditingController();
  final _myPhoneController = TextEditingController();

  List<Map<String, dynamic>> _searchResults = [];
  List<Map<String, dynamic>> _pendingRequests = [];
  List<Map<String, dynamic>> _friendsList = [];
  List<Map<String, dynamic>> _sentRequests = [];

  // HIGH FIX #16: Pagination for friends list
  int _friendsPage = 0;
  bool _isLoadingMoreFriends = false;
  bool _hasMoreFriends = true;
  static const int _friendsPageSize = 50;

  // HIGH FIX #9: Friend request rate limiting
  DateTime? _lastFriendRequestTime;
  static const _friendRequestCooldown = Duration(seconds: 10);

  bool _isSyncingContacts = false;
  bool _contactsSyncEnabled = false;
  bool _isPhoneLinked = false;
  String? _contactsError;
  String? _myPhoneError;
  List<Map<String, dynamic>> _matchedContacts = [];
  final Map<String, Map<String, String>> _contactByHash = {};
  int _lastTabIndex = 0;

  final _shareButtonKey = GlobalKey();
  Timer? _searchDebounce;
  String? _currentUserId;
  bool _isIncognito = false;
  DateTime? _incognitoUntil;
  RealtimeChannel? _friendshipsChannel;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(_onTabChanged);
    _currentUserId = Supabase.instance.client.auth.currentUser?.id;
    _loadIncognitoStatus();
    _loadPhoneLinkStatus();
    _loadFriendships();
    _subscribeToFriendships();
    _loadContactsSyncPreference();
  }

  Future<void> _loadPhoneLinkStatus() async {
    if (_currentUserId == null) return;
    try {
      final resp = await Supabase.instance.client
          .from('profiles')
          .select('phone_hash')
          .eq('id', _currentUserId!)
          .maybeSingle();

      final phoneHash = resp?['phone_hash'] as String?;
      if (!mounted) return;
      setState(() {
        _isPhoneLinked = phoneHash != null && phoneHash.isNotEmpty;
      });
    } catch (e) {
      debugPrint('[friends] load phone link status failed: $e');
    }
  }

  Future<void> _loadContactsSyncPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('contacts_sync_enabled') ?? false;
    if (!mounted) return;
    setState(() {
      _contactsSyncEnabled = enabled;
    });
  }

  Future<void> _setContactsSyncEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('contacts_sync_enabled', enabled);
    if (!mounted) return;

    setState(() {
      _contactsSyncEnabled = enabled;
      if (!enabled) {
        _matchedContacts = [];
        _contactsError = null;
      }
    });

    if (enabled && _tabController.index == 3 && !_isSyncingContacts) {
      unawaited(_syncPhonebook());
    }
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == _lastTabIndex) return;

    _lastTabIndex = _tabController.index;
    if (_tabController.index == 3 &&
        _contactsSyncEnabled &&
        !_isSyncingContacts) {
      unawaited(_syncPhonebook());
    }
  }

  void _subscribeToFriendships() {
    if (_currentUserId == null) return;
    _friendshipsChannel = Supabase.instance.client
        .channel('friends_screen_$_currentUserId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'friendships',
          callback: (_) => _loadFriendships(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'friendships',
          callback: (_) => _loadFriendships(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'friendships',
          callback: (_) => _loadFriendships(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    _friendshipsChannel?.unsubscribe();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    _myPhoneController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadIncognitoStatus() async {
    if (_currentUserId == null) return;

    try {
      final resp = await Supabase.instance.client
          .from('profiles')
          .select('is_incognito, incognito_until')
          .eq('id', _currentUserId!)
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
        });
      }
    } catch (e) {
      debugPrint('[friends] Error loading incognito status: $e');
    }
  }

  Future<void> _loadFriendships() async {
    if (_currentUserId == null) return;

    // Reset pagination when reloading
    _friendsPage = 0;
    _hasMoreFriends = true;
    await _loadMoreFriends();
  }

  Future<void> _loadMoreFriends() async {
    if (_currentUserId == null || _isLoadingMoreFriends || !_hasMoreFriends)
      return;

    _isLoadingMoreFriends = true;

    try {
      // CRITICAL FIX #1: Combined query instead of 4 separate queries (N+1 problem)
      // Use OR filter to get all friendships in one query
      final resp = await Supabase.instance.client
          .from('friendships')
          .select('''
            id,
            requester_id,
            addressee_id,
            status,
            created_at,
            requester:profiles!friendships_requester_id_fkey(handle, avatar_url),
            addressee:profiles!friendships_addressee_id_fkey(handle, avatar_url)
          ''')
          .or('requester_id.eq.$_currentUserId,addressee_id.eq.$_currentUserId')
          .order('created_at', ascending: false)
          // HIGH FIX #16: Implement pagination to avoid loading all friends at once
          .range(
            _friendsPage * _friendsPageSize,
            (_friendsPage + 1) * _friendsPageSize - 1,
          );

      // Parse results into appropriate lists
      final List<Map<String, dynamic>> pendingResp = [];
      final List<Map<String, dynamic>> sentResp = [];
      final List<Map<String, dynamic>> acceptedFriends = [];

      for (final item in resp) {
        final map = Map<String, dynamic>.from(item as Map);
        final status = map['status'] as String?;
        final addresseeId = map['addressee_id'] as String?;

        if (status == 'pending') {
          if (addresseeId == _currentUserId) {
            pendingResp.add(map);
          } else {
            sentResp.add(map);
          }
        } else if (status == 'accepted') {
          acceptedFriends.add(map);
        }
      }

      // Combine both directions for accepted friends
      final allFriends = <Map<String, dynamic>>[];
      for (final item in acceptedFriends) {
        final requesterId = item['requester_id'] as String?;
        final addresseeId = item['addressee_id'] as String?;
        final userId = requesterId == _currentUserId
            ? addresseeId
            : requesterId;

        if (requesterId == _currentUserId) {
          final addressee = item['addressee'] as Map?;
          if (addressee != null && addressee['handle'] != null) {
            allFriends.add({
              'id': item['id'],
              'user_id': userId,
              'handle': addressee['handle'],
              'avatar_url': addressee['avatar_url'],
            });
          }
        } else {
          final requester = item['requester'] as Map?;
          if (requester != null && requester['handle'] != null) {
            allFriends.add({
              'id': item['id'],
              'user_id': userId,
              'handle': requester['handle'],
              'avatar_url': requester['avatar_url'],
            });
          }
        }
      }

      if (mounted) {
        setState(() {
          // On first page, replace; otherwise append
          if (_friendsPage == 0) {
            _pendingRequests = pendingResp.cast<Map<String, dynamic>>();
            _sentRequests = sentResp.cast<Map<String, dynamic>>();
            _friendsList = allFriends;
          } else {
            _friendsList.addAll(allFriends);
          }

          // Check if there are more results
          _hasMoreFriends = resp.length >= _friendsPageSize;
          _friendsPage++;
        });
        // Keep search results in sync with the updated friendship state.
        if (_searchController.text.trim().isNotEmpty && _friendsPage == 1) {
          _searchUsers(_searchController.text);
        }
      }
    } catch (e) {
      debugPrint('[friends] Error loading friendships: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading friendships: $e')),
        );
      }
    } finally {
      _isLoadingMoreFriends = false;
    }
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      _searchUsers(query);
    });
  }

  Future<void> _searchUsers(String query) async {
    // Disable search when incognito
    if (_isIncognito) {
      setState(() => _searchResults = []);
      return;
    }

    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    try {
      // CRITICAL FIX #2: SQL injection protection - sanitize search query
      final searchQuery = ValidationHelpers.sanitizeSearchQuery(query);
      final resp = await Supabase.instance.client
          .from('profiles')
          .select('id, handle, avatar_url')
          .ilike('handle', '%$searchQuery%')
          .limit(20);

      // Filter out current user and existing friends/requests
      // HIGH FIX #13: Use Set for deduplication
      final resultIds = <String>{};
      final results = <Map<String, dynamic>>[];

      for (final item in resp) {
        final map = Map<String, dynamic>.from(item as Map);
        final userId = map['id'] as String?;

        // Skip current user, duplicates, and null IDs
        if (userId == null ||
            userId == _currentUserId ||
            resultIds.contains(userId))
          continue;
        resultIds.add(userId);

        // Mark status for UI
        String status = 'none';

        // Check if already friends
        final alreadyFriend = _friendsList.any((f) => f['user_id'] == userId);
        if (alreadyFriend) {
          status = 'friend';
        }

        // Check if request already sent
        final requestSent = _sentRequests.any(
          (r) => r['addressee_id'] == userId,
        );
        if (requestSent) {
          status = 'sent';
        }

        // Check if request already received
        final requestReceived = _pendingRequests.any(
          (r) => r['requester_id'] == userId,
        );
        if (requestReceived) {
          status = 'received';
        }

        map['friendship_status'] = status;
        results.add(map);
      }

      if (mounted) {
        setState(() {
          _searchResults = results;
        });
      }
    } catch (e) {
      debugPrint('[friends] Search error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Search error: $e')));
      }
    }
  }

  Future<void> _saveMyPhoneHash() async {
    if (_currentUserId == null) return;

    final raw = _myPhoneController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _myPhoneError = 'Please enter your phone number first.';
      });
      return;
    }

    final hash = ValidationHelpers.hashPhoneE164(raw);
    if (hash == null) {
      setState(() {
        _myPhoneError = 'Invalid phone number format.';
      });
      return;
    }

    try {
      await Supabase.instance.client
          .from('profiles')
          .update({'phone_hash': hash})
          .eq('id', _currentUserId!);

      if (mounted) {
        setState(() {
          _myPhoneError = null;
          _isPhoneLinked = true;
          _myPhoneController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Your phone number is now linked.')),
        );
        await _loadPhoneLinkStatus();
      }
    } catch (e) {
      debugPrint('[friends] save phone hash failed: $e');
      if (mounted) {
        final msg = e.toString().contains('phone_hash')
            ? 'Das hat gerade nicht geklappt. Bitte versuche es in ein paar Minuten erneut.'
            : 'Deine Nummer konnte nicht gespeichert werden. Bitte versuche es erneut.';
        setState(() {
          _myPhoneError = msg;
        });
      }
    }
  }

  void _startPhoneRelink() {
    setState(() {
      _isPhoneLinked = false;
      _myPhoneError = null;
      _myPhoneController.clear();
    });
  }

  Future<void> _syncPhonebook() async {
    if (_currentUserId == null) return;
    if (!Platform.isIOS) {
      setState(() {
        _contactsError = 'Phonebook sync is currently available on iOS only.';
      });
      return;
    }

    setState(() {
      _isSyncingContacts = true;
      _contactsError = null;
    });

    try {
      final dynamic raw = await _contactsChannel.invokeMethod('getContacts');
      final contacts = (raw as List<dynamic>? ?? <dynamic>[])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      final hashes = <String>{};
      final seenLocalHashes = <String>{};
      _contactByHash.clear();

      for (final contact in contacts) {
        final name = (contact['name'] as String?)?.trim();
        final phones =
            (contact['phones'] as List?)?.whereType<String>() ??
            const <String>[];

        for (final phone in phones) {
          final hash = ValidationHelpers.hashPhoneE164(phone);
          if (hash == null) continue;
          hashes.add(hash);

          final cleanedName = (name == null || name.isEmpty) ? 'Unknown' : name;
          _contactByHash.putIfAbsent(
            hash,
            () => {'name': cleanedName, 'phone': phone},
          );

          // Avoid duplicate UI rows when the same number appears multiple times
          // (different formatting, linked contacts, or repeated phone labels).
          if (seenLocalHashes.add(hash)) {
            // first occurrence per normalized number is enough
          }
        }
      }

      if (hashes.isEmpty) {
        if (mounted) {
          setState(() {
            _matchedContacts = [];
            _contactsError = 'No valid numbers found in your contacts.';
            _isSyncingContacts = false;
          });
        }
        return;
      }

      final matched = <Map<String, dynamic>>[];
      final hashList = hashes.toList(growable: false);
      const chunkSize = 100;

      for (var i = 0; i < hashList.length; i += chunkSize) {
        final end = (i + chunkSize > hashList.length)
            ? hashList.length
            : i + chunkSize;
        final chunk = hashList.sublist(i, end);

        final resp = await Supabase.instance.client
            .from('profiles')
            .select('id, handle, avatar_url, phone_hash')
            .inFilter('phone_hash', chunk)
            .neq('id', _currentUserId!);

        for (final item in resp) {
          final map = Map<String, dynamic>.from(item as Map);
          final userId = map['id'] as String?;
          if (userId == null) continue;

          String status = 'none';
          if (_friendsList.any((f) => f['user_id'] == userId)) {
            status = 'friend';
          } else if (_sentRequests.any((r) => r['addressee_id'] == userId)) {
            status = 'sent';
          } else if (_pendingRequests.any((r) => r['requester_id'] == userId)) {
            status = 'received';
          }
          map['friendship_status'] = status;
          matched.add(map);
        }
      }

      if (mounted) {
        setState(() {
          _matchedContacts = matched;
          _isSyncingContacts = false;
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _contactsError = e.message ?? 'Could not read contacts.';
          _isSyncingContacts = false;
        });
      }
    } catch (e) {
      debugPrint('[friends] contact sync failed: $e');
      if (mounted) {
        final msg = e.toString().contains('phone_hash')
            ? 'Kontakte konnten gerade nicht synchronisiert werden. Bitte versuche es in ein paar Minuten erneut.'
            : 'Kontakte konnten nicht synchronisiert werden. Bitte versuche es erneut.';
        setState(() {
          _contactsError = msg;
          _isSyncingContacts = false;
        });
      }
    }
  }

  Future<void> _sendFriendRequest(String addresseeId) async {
    if (_currentUserId == null) return;

    // Prevent sending requests while incognito
    if (_isIncognito) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot send friend requests in Incognito Mode'),
            backgroundColor: Colors.deepPurple,
          ),
        );
      }
      return;
    }

    // HIGH FIX #9: Rate limiting on friend requests
    if (_lastFriendRequestTime != null) {
      final timeSinceLastRequest = DateTime.now().difference(
        _lastFriendRequestTime!,
      );
      if (timeSinceLastRequest < _friendRequestCooldown) {
        final remainingSeconds =
            _friendRequestCooldown.inSeconds - timeSinceLastRequest.inSeconds;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Please wait ${remainingSeconds}s before sending another request',
              ),
            ),
          );
        }
        return;
      }
    }

    try {
      // Check if friendship already exists (in either direction)
      final existing = await Supabase.instance.client
          .from('friendships')
          .select('id, status')
          .or(
            'and(requester_id.eq.$_currentUserId,addressee_id.eq.$addresseeId),and(requester_id.eq.$addresseeId,addressee_id.eq.$_currentUserId)',
          )
          .maybeSingle();

      if (existing != null) {
        final status = existing['status'] as String?;
        String message;
        if (status == 'pending') {
          message = 'Anfrage bereits gesendet oder erhalten!';
        } else if (status == 'accepted') {
          message = 'Ihr seid bereits Freunde!';
        } else {
          message = 'Eine Anfrage existiert bereits.';
        }

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
        return;
      }

      // Create new friendship request with retry logic
      int retryCount = 0;
      const maxRetries = 3;
      while (retryCount < maxRetries) {
        try {
          await Supabase.instance.client.from('friendships').insert({
            'requester_id': _currentUserId,
            'addressee_id': addresseeId,
            'status': 'pending',
          });
          break;
        } catch (e) {
          retryCount++;
          if (retryCount >= maxRetries) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }

      // Update rate limiter
      _lastFriendRequestTime = DateTime.now();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Friend request sent! ✓')));

        // Refresh lists first
        await _loadFriendships();

        // Re-run search to update results (remove sent request from list)
        if (_searchController.text.isNotEmpty) {
          await _searchUsers(_searchController.text);
        }
      }
    } catch (e) {
      debugPrint('[friends] Error sending request: $e');
      if (mounted) {
        String errorMsg = 'Error sending request';
        if (e.toString().contains('duplicate key')) {
          errorMsg = 'Request already sent!';
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorMsg)));
      }
    }
  }

  Future<void> _acceptRequest(String friendshipId) async {
    try {
      await Supabase.instance.client
          .from('friendships')
          .update({
            'status': 'accepted',
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', friendshipId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Friendship accepted! 🎉')),
        );
        await _loadFriendships();
      }
    } catch (e) {
      debugPrint('[friends] Error accepting request: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error accepting: $e')));
      }
    }
  }

  Future<void> _rejectRequest(String friendshipId) async {
    try {
      await Supabase.instance.client
          .from('friendships')
          .update({
            'status': 'rejected',
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', friendshipId);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Request rejected')));
        await _loadFriendships();
      }
    } catch (e) {
      debugPrint('[friends] Error rejecting request: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error rejecting: $e')));
      }
    }
  }

  Future<void> _removeFriend(String friendshipId) async {
    if (_currentUserId == null) return;
    try {
      // Use select() so we can verify whether the row was actually deleted.
      // The RLS policy may only allow deletion when the current user is the
      // requester, so we also filter on that column as a fallback. Because
      // the friendship row could be in either direction we try both.
      final deleted = await Supabase.instance.client
          .from('friendships')
          .delete()
          .eq('id', friendshipId)
          .or('requester_id.eq.$_currentUserId,addressee_id.eq.$_currentUserId')
          .select('id');

      debugPrint('[friends] Remove result: $deleted');

      if (!mounted) return;

      if (deleted.isEmpty) {
        // Row wasn't deleted — likely an RLS policy gap. Try a workaround by
        // updating the status to 'removed' so either side can trigger it.
        debugPrint('[friends] Delete returned 0 rows — trying status update');
        await Supabase.instance.client
            .from('friendships')
            .update({'status': 'removed'})
            .eq('id', friendshipId)
            .or(
              'requester_id.eq.$_currentUserId,addressee_id.eq.$_currentUserId',
            );
      }

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Friend removed')));
        await _loadFriendships();
      }
    } catch (e) {
      debugPrint('[friends] Error removing friend: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error removing: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(elevation: 0, title: const Text('friends.')),

      body: Column(
        children: [
          Material(
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Search', icon: const Icon(Icons.search)),
                Tab(
                  text: 'Requests (${_pendingRequests.length})',
                  icon: const Icon(Icons.mail),
                ),
                Tab(
                  text: 'Friends (${_friendsList.length})',
                  icon: const Icon(Icons.people),
                ),
                const Tab(text: 'Contacts', icon: Icon(Icons.contacts)),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildSearchTab(),
                _buildRequestsTab(),
                _buildFriendsTab(),
                _buildContactsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? _resolveAvatarUrl(String? stored) {
    if (stored == null) return null;
    if (stored.startsWith('http')) return stored;
    return Supabase.instance.client.storage
        .from('avatars')
        .getPublicUrl(stored);
  }

  Widget _avatarCircle(
    String? avatarStored,
    String handle, {
    double radius = 20,
    Color fallbackColor = Colors.deepOrange,
  }) {
    final url = _resolveAvatarUrl(avatarStored);
    if (url != null) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: fallbackColor,
        backgroundImage: NetworkImage(url),
        onBackgroundImageError: (_, _) {},
        child: null,
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: fallbackColor,
      child: Text(
        handle[0].toUpperCase(),
        style: TextStyle(color: Colors.white, fontSize: radius * 0.9),
      ),
    );
  }

  Widget _buildSearchTab() {
    return Column(
      children: [
        // Inkognito Banner
        if (_isIncognito)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.all(16),
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
                  size: 28,
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
                        'Search disabled while you are invisible',
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

        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _searchController,
            enabled: !_isIncognito,
            decoration: InputDecoration(
              hintText: _isIncognito
                  ? 'Search disabled in Incognito Mode'
                  : 'Search by handle...',
              prefixIcon: Icon(
                Icons.search,
                color: _isIncognito
                    ? Colors.deepPurple.withValues(alpha: 0.5)
                    : null,
              ),
              filled: true,
              fillColor: _isIncognito
                  ? Colors.deepPurple.withValues(alpha: 0.08)
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: _isIncognito
                    ? const BorderSide(color: Colors.deepPurple, width: 1)
                    : BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: _isIncognito
                    ? BorderSide(
                        color: Colors.deepPurple.withValues(alpha: 0.5),
                        width: 1,
                      )
                    : BorderSide.none,
              ),
            ),
            onChanged: _onSearchChanged,
          ),
        ),
        Expanded(
          child: _searchResults.isEmpty
              ? _searchController.text.isEmpty && !_isIncognito
                    ? _buildShareHangPrompt()
                    : Center(child: Text(_isIncognito ? '' : 'No users found'))
              : ListView.builder(
                  itemCount: _searchResults.length,
                  itemBuilder: (context, index) {
                    final user = _searchResults[index];
                    final handle = user['handle'] as String;
                    final userId = user['id'] as String;
                    final status =
                        user['friendship_status'] as String? ?? 'none';

                    Widget trailingWidget;
                    switch (status) {
                      case 'friend':
                        trailingWidget = Chip(
                          label: const Text('Friend'),
                          backgroundColor: Colors.green[700],
                          labelStyle: const TextStyle(color: Colors.white),
                        );
                        break;
                      case 'sent':
                        trailingWidget = Chip(
                          label: const Text('Request sent'),
                          backgroundColor: Colors.orange[700],
                          labelStyle: const TextStyle(color: Colors.white),
                        );
                        break;
                      case 'received':
                        trailingWidget = Chip(
                          label: const Text('Request received'),
                          backgroundColor: Colors.blue[700],
                          labelStyle: const TextStyle(color: Colors.white),
                        );
                        break;
                      default:
                        trailingWidget = ElevatedButton.icon(
                          onPressed: () => _sendFriendRequest(userId),
                          icon: const Icon(Icons.person_add, size: 18),
                          label: const Text('Add'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepOrange[600],
                            foregroundColor: Colors.white,
                          ),
                        );
                    }

                    return ListTile(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              ProfileScreen(userId: userId, handle: handle),
                        ),
                      ),
                      leading: _avatarCircle(
                        user['avatar_url'] as String?,
                        handle,
                      ),
                      title: Text(
                        '@$handle',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      trailing: trailingWidget,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildShareHangPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.people_outline, size: 56, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Find your friends',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Search by handle to add friends, or invite someone to hang.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              key: _shareButtonKey,
              onPressed: () {
                final box =
                    _shareButtonKey.currentContext?.findRenderObject()
                        as RenderBox?;
                Share.share(
                  'Hey! Join me on hang. — the app that lets you know when friends are nearby. Download it here: https://hangsocial.app',
                  sharePositionOrigin: box != null
                      ? box.localToGlobal(Offset.zero) & box.size
                      : null,
                );
              },
              icon: const Icon(Icons.share),
              label: const Text('Invite a friend'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequestsTab() {
    if (_pendingRequests.isEmpty) {
      return const Center(child: Text('No pending requests'));
    }

    return ListView.builder(
      itemCount: _pendingRequests.length,
      itemBuilder: (context, index) {
        final request = _pendingRequests[index];
        final friendshipId = request['id'] as String;
        final requester = request['requester'] as Map?;
        final handle = requester?['handle'] as String? ?? 'Unknown';
        final avatarStored = requester?['avatar_url'] as String?;

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _avatarCircle(avatarStored, handle),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '@$handle',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'wants to be your friend',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _acceptRequest(friendshipId),
                  icon: const Icon(Icons.check_circle),
                  color: Colors.green,
                  tooltip: 'Accept',
                ),
                IconButton(
                  onPressed: () => _rejectRequest(friendshipId),
                  icon: const Icon(Icons.cancel),
                  color: Colors.red,
                  tooltip: 'Reject',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFriendsTab() {
    if (_friendsList.isEmpty) {
      return const Center(
        child: Text(
          'No friends yet.\nSearch for handles to add friends!',
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.builder(
      itemCount: _friendsList.length,
      itemBuilder: (context, index) {
        final friend = _friendsList[index];
        final handle = friend['handle'] as String;
        final friendshipId = friend['id'] as String;

        return ListTile(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ProfileScreen(
                userId: friend['user_id'] as String,
                handle: handle,
              ),
            ),
          ),
          leading: _avatarCircle(
            friend['avatar_url'] as String?,
            handle,
            fallbackColor: Colors.green,
          ),
          title: Text(
            '@$handle',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.person_remove, color: Colors.red),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Remove friend?'),
                  content: Text(
                    'Do you really want to remove @$handle from your friends?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _removeFriend(friendshipId);
                      },
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              );
            },
            tooltip: 'Freund entfernen',
          ),
        );
      },
    );
  }

  Widget _buildContactsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 140),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_isPhoneLinked)
            const Text(
              'Find friends from your iPhone contacts',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          if (!_isPhoneLinked) const SizedBox(height: 8),
          if (!_isPhoneLinked)
            Text(
              'First link your own number, then sync your phonebook.',
              style: const TextStyle(color: Colors.grey),
            ),
          const SizedBox(height: 16),
          if (_isPhoneLinked)
            Row(
              children: [
                Expanded(
                  flex: 70,
                  child: Row(
                    children: [
                      const Icon(Icons.verified, color: Colors.green, size: 18),
                      const SizedBox(width: 8),
                      const Text(
                        'Linked',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _startPhoneRelink,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(40, 30),
                        ),
                        child: const Text(
                          'Change my number',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 30,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'sync',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (_isSyncingContacts)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Switch(
                          value: _contactsSyncEnabled,
                          onChanged: (value) => _setContactsSyncEnabled(value),
                        ),
                    ],
                  ),
                ),
              ],
            )
          else
            Column(
              children: [
                TextField(
                  controller: _myPhoneController,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: 'Your phone number',
                    hintText: '+49 171 1234567',
                    errorText: _myPhoneError,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onChanged: (_) {
                    if (_myPhoneError != null) {
                      setState(() {
                        _myPhoneError = null;
                      });
                    }
                  },
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  onPressed: _saveMyPhoneHash,
                  icon: const Icon(Icons.verified_user),
                  label: const Text('Link My Number'),
                ),
              ],
            ),
          const SizedBox(height: 16),
          if (_contactsError != null) ...[
            const SizedBox(height: 10),
            Text(_contactsError!, style: const TextStyle(color: Colors.red)),
          ],
          const SizedBox(height: 20),
          if (_matchedContacts.isNotEmpty) ...[
            const Text(
              'Already on hang',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._matchedContacts.map((profile) {
              final handle = profile['handle'] as String? ?? 'Unknown';
              final userId = profile['id'] as String?;
              final status = profile['friendship_status'] as String? ?? 'none';
              final phoneHash = profile['phone_hash'] as String?;
              final localName = phoneHash == null
                  ? 'Contact'
                  : (_contactByHash[phoneHash]?['name'] ?? 'Contact');

              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _avatarCircle(
                  profile['avatar_url'] as String?,
                  handle,
                ),
                title: Text('@$handle'),
                subtitle: Text(localName),
                trailing: status == 'friend'
                    ? const Chip(label: Text('Friend'))
                    : status == 'sent'
                    ? const Chip(label: Text('Pending'))
                    : ElevatedButton(
                        onPressed: userId == null
                            ? null
                            : () => _sendFriendRequest(userId),
                        child: const Text('Add'),
                      ),
                onTap: userId == null
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              ProfileScreen(userId: userId, handle: handle),
                        ),
                      ),
              );
            }),
          ],
          const SizedBox(height: 20),
          Center(
            child: ElevatedButton.icon(
              key: _shareButtonKey,
              onPressed: () {
                final box =
                    _shareButtonKey.currentContext?.findRenderObject()
                        as RenderBox?;
                Share.share(
                  'Hey! Join me on hang. the app that lets you know when friends are nearby. Download it here: https://hangsocial.app',
                  sharePositionOrigin: box != null
                      ? box.localToGlobal(Offset.zero) & box.size
                      : null,
                );
              },
              icon: const Icon(Icons.share),
              label: const Text('Invite a friend'),
            ),
          ),
        ],
      ),
    );
  }
}
