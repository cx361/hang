import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  bool _isSearching = false;
  String? _currentUserId;
  bool _isIncognito = false;
  DateTime? _incognitoUntil;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _currentUserId = Supabase.instance.client.auth.currentUser?.id;
    _loadIncognitoStatus();
    _loadFriendships();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
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
            requester:profiles!friendships_requester_id_fkey(handle)
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
            addressee:profiles!friendships_addressee_id_fkey(handle)
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
            addressee:profiles!friendships_addressee_id_fkey(handle)
          ''')
          .eq('requester_id', _currentUserId!)
          .eq('status', 'accepted');

      final friendsAsAddressee = await Supabase.instance.client
          .from('friendships')
          .select('''
            id,
            requester_id,
            requester:profiles!friendships_requester_id_fkey(handle)
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
          });
        }
      }

      if (mounted) {
        setState(() {
          _pendingRequests = pendingResp.cast<Map<String, dynamic>>();
          _sentRequests = sentResp.cast<Map<String, dynamic>>();
          _friendsList = allFriends;
        });
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

  Future<void> _searchUsers(String query) async {
    // Disable search when incognito
    if (_isIncognito) {
      setState(() {
        _searchResults = [];
      });
      return;
    }

    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
      });
      return;
    }

    setState(() {
      _isSearching = true;
    });

    try {
      // Search by handle (case-insensitive)
      final searchQuery = query.trim().toLowerCase();
      final resp = await Supabase.instance.client
          .from('profiles')
          .select('id, handle')
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
          _isSearching = false;
        });
      }
    } catch (e) {
      debugPrint('[friends] Search error: $e');
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
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
            'updated_at': DateTime.now().toIso8601String(),
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
            'updated_at': DateTime.now().toIso8601String(),
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
    try {
      await Supabase.instance.client
          .from('friendships')
          .delete()
          .eq('id', friendshipId);

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
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Material(
            color: Colors.black,
            child: TabBar(
              controller: _tabController,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white60,
              indicatorColor: Colors.white,
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
              color: Colors.deepPurple.withOpacity(0.2),
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
            style: TextStyle(
              color: _isIncognito ? Colors.grey[700] : Colors.white,
            ),
            decoration: InputDecoration(
              hintText: _isIncognito
                  ? 'Search disabled in Incognito Mode'
                  : 'Search by handle...',
              hintStyle: TextStyle(color: Colors.grey[600]),
              prefixIcon: Icon(
                Icons.search,
                color: _isIncognito ? Colors.grey[700] : Colors.grey,
              ),
              filled: true,
              fillColor: _isIncognito
                  ? Colors.deepPurple.withOpacity(0.1)
                  : Colors.grey[900],
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
                        color: Colors.deepPurple.withOpacity(0.5),
                        width: 1,
                      )
                    : BorderSide.none,
              ),
            ),
            onChanged: _searchUsers,
          ),
        ),
        Expanded(
          child: _isSearching
              ? const Center(child: CircularProgressIndicator())
              : _searchResults.isEmpty
              ? Center(
                  child: Text(
                    _isIncognito
                        ? ''
                        : (_searchController.text.isEmpty
                              ? 'Enter a handle to search'
                              : 'No users found'),
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
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
                      leading: CircleAvatar(
                        backgroundColor: Colors.deepOrange,
                        child: Text(
                          handle[0].toUpperCase(),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      title: Text(
                        '@$handle',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      trailing: trailingWidget,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildRequestsTab() {
    if (_pendingRequests.isEmpty) {
      return const Center(
        child: Text(
          'No pending requests',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      itemCount: _pendingRequests.length,
      itemBuilder: (context, index) {
        final request = _pendingRequests[index];
        final friendshipId = request['id'] as String;
        final requester = request['requester'] as Map?;
        final handle = requester?['handle'] as String? ?? 'Unknown';

        return Card(
          color: Colors.grey[900],
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: Colors.deepOrange,
                  child: Text(
                    handle[0].toUpperCase(),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '@$handle',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'wants to be your friend',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
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
          style: TextStyle(color: Colors.grey),
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
          leading: CircleAvatar(
            backgroundColor: Colors.green,
            child: Text(
              handle[0].toUpperCase(),
              style: const TextStyle(color: Colors.white),
            ),
          ),
          title: Text(
            '@$handle',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.person_remove, color: Colors.red),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: Colors.grey[900],
                  title: const Text(
                    'Remove friend?',
                    style: TextStyle(color: Colors.white),
                  ),
                  content: Text(
                    'Do you really want to remove @$handle from your friends?',
                    style: const TextStyle(color: Colors.grey),
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
