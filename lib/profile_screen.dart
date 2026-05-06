import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'user_friends_screen.dart';

/// Displays another user's public profile.
class ProfileScreen extends StatefulWidget {
  final String userId;
  final String handle;

  const ProfileScreen({super.key, required this.userId, required this.handle});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String? _avatarUrl;
  bool _avatarError = false;
  bool _loading = true;
  String? _friendshipStatus; // 'none' | 'friend' | 'sent' | 'received'
  String? _friendshipId;
  int _friendCount = 0;
  int _mutualCount = 0;
  String? _updatedAt;
  bool _targetShowsActivity = false;
  final _currentUserId = Supabase.instance.client.auth.currentUser?.id;

  static String? _resolveAvatarUrl(String? stored) {
    if (stored == null) return null;
    if (stored.startsWith('http')) return stored;
    return Supabase.instance.client.storage
        .from('avatars')
        .getPublicUrl(stored);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uid = widget.userId;

      final profileFuture = Supabase.instance.client
          .from('profiles')
          .select('avatar_url, updated_at, show_activity')
          .eq('id', uid)
          .single();

      final friendshipFuture = _currentUserId != null
          ? Supabase.instance.client
                .from('friendships')
                .select('id, status, requester_id')
                .or(
                  'and(requester_id.eq.$_currentUserId,addressee_id.eq.$uid),'
                  'and(requester_id.eq.$uid,addressee_id.eq.$_currentUserId)',
                )
                .maybeSingle()
          : Future<Map<String, dynamic>?>.value(null);

      final friendCountFuture = Supabase.instance.client.rpc(
        'get_user_friend_count',
        params: {'target_user_id': uid},
      );

      final mutualFuture = (_currentUserId != null && _currentUserId != uid)
          ? Supabase.instance.client.rpc(
              'get_mutual_friend_count',
              params: {'user_a': _currentUserId, 'user_b': uid},
            )
          : Future<dynamic>.value(0);

      final results = await Future.wait<dynamic>([
        profileFuture,
        friendshipFuture,
        friendCountFuture,
        mutualFuture,
      ]);

      final profile = results[0] as Map<String, dynamic>;
      final friendship = results[1] as Map<String, dynamic>?;
      final friendCount = (results[2] as int?) ?? 0;
      final mutualCount = (results[3] as int?) ?? 0;

      String status = 'none';
      String? fid;
      if (friendship != null) {
        fid = friendship['id'] as String?;
        final fStatus = friendship['status'] as String?;
        final requesterId = friendship['requester_id'] as String?;
        if (fStatus == 'accepted') {
          status = 'friend';
        } else if (fStatus == 'pending') {
          status = requesterId == _currentUserId ? 'sent' : 'received';
        }
      }

      if (mounted) {
        setState(() {
          _avatarUrl = _resolveAvatarUrl(profile['avatar_url'] as String?);
          _avatarError = false;
          _friendshipStatus = status;
          _friendshipId = fid;
          _friendCount = friendCount;
          _mutualCount = mutualCount;
          _updatedAt = profile['updated_at'] as String?;
          _targetShowsActivity = profile['show_activity'] as bool? ?? false;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('[profile] Error loading: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendRequest() async {
    if (_currentUserId == null) return;
    try {
      await Supabase.instance.client.from('friendships').insert({
        'requester_id': _currentUserId,
        'addressee_id': widget.userId,
        'status': 'pending',
      });
      if (mounted) setState(() => _friendshipStatus = 'sent');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _acceptRequest() async {
    if (_friendshipId == null) return;
    try {
      await Supabase.instance.client
          .from('friendships')
          .update({'status': 'accepted'})
          .eq('id', _friendshipId!);
      if (mounted) setState(() => _friendshipStatus = 'friend');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _removeFriend() async {
    if (_friendshipId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove friend?'),
        content: Text('Remove @${widget.handle} from your friends?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Supabase.instance.client
          .from('friendships')
          .delete()
          .eq('id', _friendshipId!);
      if (mounted) {
        setState(() {
          _friendshipStatus = 'none';
          _friendshipId = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  String? _activityLabel() {
    if (!_targetShowsActivity || _updatedAt == null) return null;
    try {
      final age = DateTime.now().difference(DateTime.parse(_updatedAt!));
      if (age.inDays >= 7) return 'inactive hang user';
      final String t;
      if (age.inMinutes < 10) {
        t = '<10min';
      } else if (age.inMinutes < 30) {
        t = '<30min';
      } else if (age.inHours < 1) {
        t = '<1h';
      } else if (age.inHours < 2) {
        t = '<2h';
      } else if (age.inHours < 24) {
        t = '${age.inHours}h ago';
      } else {
        t = '${age.inDays}d ago';
      }
      return 'active hang user • $t';
    } catch (_) {
      return null;
    }
  }

  Widget _buildActionButton() {
    switch (_friendshipStatus) {
      case 'friend':
        return OutlinedButton.icon(
          onPressed: _removeFriend,
          icon: const Icon(Icons.person_remove, size: 18),
          label: const Text('Friends'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.green[400],
            side: BorderSide(color: Colors.green[400]!),
          ),
        );
      case 'sent':
        return OutlinedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.hourglass_empty, size: 18),
          label: const Text('Request sent'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.orange[400],
            side: BorderSide(color: Colors.orange[400]!),
          ),
        );
      case 'received':
        return ElevatedButton.icon(
          onPressed: _acceptRequest,
          icon: const Icon(Icons.check, size: 18),
          label: const Text('Accept request'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFF8C00),
            foregroundColor: Colors.black,
          ),
        );
      default:
        return ElevatedButton.icon(
          onPressed: _sendRequest,
          icon: const Icon(Icons.person_add, size: 18),
          label: const Text('Add friend'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFF8C00),
            foregroundColor: Colors.black,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(elevation: 0, title: Text('@${widget.handle}')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFFF8C00)),
            )
          : Column(
              children: [
                const SizedBox(height: 40),
                // Avatar
                Center(
                  child: _avatarUrl != null && !_avatarError
                      ? CircleAvatar(
                          radius: 56,
                          backgroundImage: NetworkImage(_avatarUrl!),
                          onBackgroundImageError: (_, _) {
                            if (mounted) setState(() => _avatarError = true);
                          },
                        )
                      : CircleAvatar(
                          radius: 56,
                          backgroundColor: const Color(0xFF311B00),
                          child: Text(
                            widget.handle[0].toUpperCase(),
                            style: const TextStyle(
                              color: Color(0xFFFF8A00),
                              fontSize: 40,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 20),
                Text(
                  '@${widget.handle}',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_activityLabel() != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _activityLabel()!,
                    style: TextStyle(
                      color: _activityLabel()!.startsWith('inactive')
                          ? Colors.white38
                          : Colors.green[400],
                      fontSize: 13,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => UserFriendsScreen(
                        userId: widget.userId,
                        handle: widget.handle,
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        '$_friendCount',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'friends',
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.5),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_currentUserId != null &&
                    _currentUserId != widget.userId &&
                    _mutualCount > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '$_mutualCount mutual ${_mutualCount == 1 ? 'friend' : 'friends'}',
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.4),
                      fontSize: 13,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                if (_currentUserId != null && _currentUserId != widget.userId)
                  _buildActionButton(),
              ],
            ),
    );
  }
}
