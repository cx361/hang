import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'profile_screen.dart';

/// Shows the friends list of any user. Tapping a friend navigates to their
/// ProfileScreen, which itself shows their friends — enabling recursive
/// profile browsing.
class UserFriendsScreen extends StatefulWidget {
  final String userId;
  final String handle;

  const UserFriendsScreen({
    super.key,
    required this.userId,
    required this.handle,
  });

  @override
  State<UserFriendsScreen> createState() => _UserFriendsScreenState();
}

class _UserFriendsScreenState extends State<UserFriendsScreen> {
  List<Map<String, dynamic>> _friends = [];
  bool _loading = true;

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

      // Uses a SECURITY DEFINER RPC to bypass RLS, which would otherwise only
      // return rows where the current user is involved.
      final rows =
          await Supabase.instance.client.rpc(
                'get_user_friends',
                params: {'target_user_id': uid},
              )
              as List<dynamic>;

      final friends = rows.map((item) {
        final m = Map<String, dynamic>.from(item as Map);
        return {
          'user_id': m['user_id'],
          'handle': m['handle'],
          'avatar_url': _resolveAvatarUrl(m['avatar_url'] as String?),
        };
      }).toList();

      if (mounted) {
        setState(() {
          _friends = friends.cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('[user_friends] Error loading: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(elevation: 0, title: Text('friends of @${widget.handle}')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFFF8C00)),
            )
          : _friends.isEmpty
          ? const Center(child: Text('Noch keine Freunde.'))
          : ListView.builder(
              itemCount: _friends.length,
              itemBuilder: (context, index) {
                final f = _friends[index];
                final avatarUrl = f['avatar_url'] as String?;
                final handle = f['handle'] as String;
                return ListTile(
                  leading: avatarUrl != null
                      ? CircleAvatar(
                          backgroundImage: NetworkImage(avatarUrl),
                          backgroundColor: const Color(0xFF311B00),
                        )
                      : CircleAvatar(
                          backgroundColor: const Color(0xFF311B00),
                          child: Text(
                            handle[0].toUpperCase(),
                            style: const TextStyle(
                              color: Color(0xFFFF8A00),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                  title: Text(
                    '@$handle',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.3),
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ProfileScreen(
                        userId: f['user_id'] as String,
                        handle: handle,
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
