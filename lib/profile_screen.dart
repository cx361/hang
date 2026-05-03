import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  bool _loading = true;
  String? _friendshipStatus; // 'none' | 'friend' | 'sent' | 'received'
  String? _friendshipId;
  final _currentUserId = Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        Supabase.instance.client
            .from('profiles')
            .select('avatar_url')
            .eq('id', widget.userId)
            .single(),
        if (_currentUserId != null)
          Supabase.instance.client
              .from('friendships')
              .select('id, status, requester_id')
              .or(
                'and(requester_id.eq.$_currentUserId,addressee_id.eq.${widget.userId}),'
                'and(requester_id.eq.${widget.userId},addressee_id.eq.$_currentUserId)',
              )
              .maybeSingle(),
      ]);

      final profile = results[0] as Map<String, dynamic>;
      final friendship = results.length > 1 ? results[1] : null;

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
          _avatarUrl = profile['avatar_url'] as String?;
          _friendshipStatus = status;
          _friendshipId = fid;
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
        backgroundColor: Colors.grey[900],
        title: const Text(
          'Remove friend?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Remove @${widget.handle} from your friends?',
          style: const TextStyle(color: Colors.grey),
        ),
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
      if (mounted)
        setState(() {
          _friendshipStatus = 'none';
          _friendshipId = null;
        });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
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
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          '@${widget.handle}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFFF8C00)),
            )
          : Column(
              children: [
                const SizedBox(height: 40),
                // Avatar
                Center(
                  child: _avatarUrl != null
                      ? CircleAvatar(
                          radius: 56,
                          backgroundImage: NetworkImage(_avatarUrl!),
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
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 24),
                if (_currentUserId != null && _currentUserId != widget.userId)
                  _buildActionButton(),
              ],
            ),
    );
  }
}
