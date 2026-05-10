import 'dart:async';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'profile_screen.dart';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _searchController = TextEditingController();

  List<Map<String, dynamic>> _searchResults = [];
  List<Map<String, dynamic>> _pendingRequests = [];
  List<Map<String, dynamic>> _friendsList = [];
  List<Map<String, dynamic>> _sentRequests = [];

  final _shareButtonKey = GlobalKey();
  Timer? _searchDebounce;
  String? _currentUserId;
  bool _isIncognito = false;
  DateTime? _incognitoUntil;
  RealtimeChannel? _friendshipsChannel;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _currentUserId = Supabase.instance.client.auth.currentUser?.id;
    _loadIncognitoStatus();
    _loadFriendships();
    _subscribeToFriendships();
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
    _tabController.dispose();
    _searchController.dispose();
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

    try {
      // Load pending incoming requests
      final pendingResp = await Supabase.instance.client
          .from('friendships')
          .select('''
            id,
            requester_id,
            status,
            created_at,
            requester:profiles!friendships_requester_id_fkey(handle, avatar_url)
          ''')
          .eq('addressee_id', _currentUserId!)
          .eq('status', 'pending')
          .order('created_at', ascending: false);

      // Load sent requests
      final sentResp = await Supabase.instance.client
          .from('friendships')
          .select('''
            id,
            addressee_id,
            status,
            created_at,
            addressee:profiles!friendships_addressee_id_fkey(handle, avatar_url)
          ''')
          .eq('requester_id', _currentUserId!)
          .eq('status', 'pending')
          .order('created_at', ascending: false);

      // Load accepted friends
      final friendsAsRequester = await Supabase.instance.client
          .from('friendships')
          .select('''
            id,
            addressee_id,
            addressee:profiles!friendships_addressee_id_fkey(handle, avatar_url)
          ''')
          .eq('requester_id', _currentUserId!)
          .eq('status', 'accepted');

      final friendsAsAddressee = await Supabase.instance.client
          .from('friendships')
          .select('''
            id,
            requester_id,
            requester:profiles!friendships_requester_id_fkey(handle, avatar_url)
          ''')
          .eq('addressee_id', _currentUserId!)
          .eq('status', 'accepted');

      // Combine both directions
      final allFriends = <Map<String, dynamic>>[];
      for (final item in friendsAsRequester) {
        final map = Map<String, dynamic>.from(item as Map);
        final addressee = map['addressee'] as Map?;
        if (addressee != null && addressee['handle'] != null) {
          allFriends.add({
            'id': map['id'],
            'user_id': map['addressee_id'],
            'handle': addressee['handle'],
            'avatar_url': addressee['avatar_url'],
          });
        }
      }
      for (final item in friendsAsAddressee) {
        final map = Map<String, dynamic>.from(item as Map);
        final requester = map['requester'] as Map?;
        if (requester != null && requester['handle'] != null) {
          allFriends.add({
            'id': map['id'],
            'user_id': map['requester_id'],
            'handle': requester['handle'],
            'avatar_url': requester['avatar_url'],
          });
        }
      }

      if (mounted) {
        setState(() {
          _pendingRequests = pendingResp.cast<Map<String, dynamic>>();
          _sentRequests = sentResp.cast<Map<String, dynamic>>();
          _friendsList = allFriends;
        });
        // Keep search results in sync with the updated friendship state.
        if (_searchController.text.trim().isNotEmpty) {
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
      // Search by handle (case-insensitive)
      final searchQuery = query.trim().toLowerCase();
      final resp = await Supabase.instance.client
          .from('profiles')
          .select('id, handle, avatar_url')
          .ilike('handle', '%$searchQuery%')
          .limit(20);

      // Filter out current user and existing friends/requests
      final results = <Map<String, dynamic>>[];
      for (final item in resp) {
        final map = Map<String, dynamic>.from(item as Map);
        final userId = map['id'] as String?;

        // Skip current user
        if (userId == _currentUserId) continue;

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

      // Create new friendship request
      await Supabase.instance.client.from('friendships').insert({
        'requester_id': _currentUserId,
        'addressee_id': addresseeId,
        'status': 'pending',
      });

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
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String? _resolveAvatarUrl(String? stored) {
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
}
