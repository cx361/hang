import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'safe_zones_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isIncognito = false;
  DateTime? _incognitoUntil;
  String? _handle;
  bool _isHandleLoading = true;
  bool _isLoading = true;
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    _loadIncognitoStatus();
    _loadHandle();

    // Update UI every minute to refresh remaining time
    _updateTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _isIncognito && _incognitoUntil != null) {
        if (DateTime.now().toUtc().isAfter(_incognitoUntil!)) {
          // Auto-disable expired incognito
          debugPrint('[incognito] Timer detected expiration - auto-disabling');
          _updateIncognitoStatus(false, null);
        } else {
          // Trigger rebuild to update time display
          setState(() {});
        }
      }
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadHandle() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      if (mounted) setState(() => _isHandleLoading = false);
      return;
    }

    try {
      final resp = await Supabase.instance.client
          .from('profiles')
          .select('handle')
          .eq('id', userId)
          .maybeSingle();

      if (mounted) {
        setState(() {
          _handle = resp == null
              ? null
              : (resp['handle'] as String?)?.toLowerCase();
          _isHandleLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[settings] Error loading handle: $e');
      if (mounted) setState(() => _isHandleLoading = false);
    }
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

          debugPrint(
            '[incognito] Loaded: is_incognito=$_isIncognito, until=$_incognitoUntil',
          );

          // Check if incognito expired
          if (_isIncognito &&
              _incognitoUntil != null &&
              DateTime.now().toUtc().isAfter(_incognitoUntil!)) {
            debugPrint('[incognito] Expired - auto-disabling');
            _isIncognito = false;
            _incognitoUntil = null;
            _updateIncognitoStatus(false, null); // Auto-disable
          }

          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[settings] Error loading incognito status: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _updateIncognitoStatus(bool enabled, DateTime? until) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      await Supabase.instance.client
          .from('profiles')
          .update({
            'is_incognito': enabled,
            'incognito_until': until?.toIso8601String(),
          })
          .eq('id', userId);

      if (mounted) {
        setState(() {
          _isIncognito = enabled;
          _incognitoUntil = until;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isIncognito
                  ? 'Incognito Mode activated 👻'
                  : 'Incognito Mode deactivated',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[settings] Error updating incognito status: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  void _showIncognitoDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Row(
          children: [
            const Icon(Icons.visibility_off, color: Colors.deepPurple),
            const SizedBox(width: 12),
            const Text('Incognito Mode', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'How long do you want to be invisible?',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            _buildDurationButton('30 Minutes', const Duration(minutes: 30)),
            _buildDurationButton('1 Hour', const Duration(hours: 1)),
            _buildDurationButton('2 Hours', const Duration(hours: 2)),
            _buildDurationButton('6 Hours', const Duration(hours: 6)),
            _buildDurationButton('24 Hours', const Duration(hours: 24)),
            _buildDurationButton('Indefinite', null),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildDurationButton(String label, Duration? duration) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () {
            Navigator.pop(context);
            final until = duration != null
                ? DateTime.now().toUtc().add(duration)
                : null;
            debugPrint(
              '[incognito] Setting until: $until (Duration: $duration)',
            );
            _updateIncognitoStatus(true, until);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepPurple,
            foregroundColor: Colors.white,
          ),
          child: Text(label),
        ),
      ),
    );
  }

  String _getIncognitoStatusText() {
    if (!_isIncognito) return 'Off';
    if (_incognitoUntil == null) return 'Active indefinitely';

    final now = DateTime.now().toUtc();
    final diff = _incognitoUntil!.difference(now);

    if (diff.isNegative) {
      return 'Expired';
    } else if (diff.inHours > 0) {
      return 'Active for ${diff.inHours}h ${diff.inMinutes.remainder(60)}min';
    } else if (diff.inMinutes > 0) {
      return 'Active for ${diff.inMinutes}min';
    } else {
      return 'Less than 1 minute';
    }
  }

  void _showEditHandleDialog() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    showDialog<void>(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: _handle ?? '');
        String? dialogError;
        bool isBusy = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> save() async {
              var newHandle = controller.text.trim().toLowerCase();
              // Allow user to type an optional leading '@' — remove it before validation
              newHandle = newHandle.replaceFirst(RegExp(r'^@+'), '');

              if (newHandle.isEmpty) {
                setDialogState(() {
                  dialogError = 'Please enter a handle';
                });
                return;
              }

              // Character validation: only lowercase a-z, 0-9, dot, underscore, hyphen
              if (!RegExp(r'^[a-z0-9._-]+$').hasMatch(newHandle)) {
                setDialogState(() {
                  dialogError =
                      'Handle may only contain lowercase letters, numbers, dot, underscore and hyphen';
                });
                return;
              }

              if (newHandle.length < 3) {
                setDialogState(() {
                  dialogError = 'Handle must be at least 3 characters long';
                });
                return;
              }

              if (newHandle.length > 20) {
                setDialogState(() {
                  dialogError = 'Handle may not exceed 20 characters';
                });
                return;
              }

              setDialogState(() => isBusy = true);

              try {
                final existing = await Supabase.instance.client
                    .from('profiles')
                    .select('id')
                    .eq('handle', newHandle)
                    .maybeSingle();

                if (existing != null && existing['id'] != userId) {
                  setDialogState(() {
                    dialogError = 'This handle is already taken';
                    isBusy = false;
                  });
                  return;
                }

                // Update handle
                await Supabase.instance.client
                    .from('profiles')
                    .update({'handle': newHandle})
                    .eq('id', userId);

                if (mounted) {
                  setState(() => _handle = newHandle);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Handle updated')),
                  );
                }

                Navigator.pop(context);
              } catch (e) {
                setDialogState(() {
                  dialogError = 'Error: $e';
                  isBusy = false;
                });
              }
            }

            return Dialog(
              backgroundColor: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey[850],
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Edit Handle',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        prefixText: '@',
                        prefixStyle: const TextStyle(
                          color: Color(0xFFFF8800),
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                        labelText: 'Handle',
                        labelStyle: const TextStyle(color: Colors.white70),
                        hintText:
                            'Only lowercase letters, numbers, dot (.), underscore (_) and hyphen (-)',
                        hintStyle: const TextStyle(color: Colors.white30),
                        filled: true,
                        fillColor: Colors.white10,
                        enabledBorder: OutlineInputBorder(
                          borderSide: const BorderSide(color: Colors.white24),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: const BorderSide(
                            color: Color(0xFFFF8800),
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    if (dialogError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        dialogError!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: isBusy
                              ? null
                              : () => Navigator.pop(context),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white70,
                          ),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: isBusy ? null : save,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF8800),
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: isBusy
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 8.0,
                                    vertical: 6.0,
                                  ),
                                  child: Text('Save'),
                                ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    final email = user?.email ?? 'Nicht angemeldet';

    return Scaffold(
      backgroundColor: Colors.black,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const SizedBox(height: 20),
                // Account Section
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Account',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(Icons.email, color: Colors.white70),
                  title: const Text(
                    'E-Mail',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    email,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(Icons.person, color: Colors.white70),
                  title: const Text(
                    'Handle',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: _isHandleLoading
                      ? const Text(
                          'Loading...',
                          style: TextStyle(color: Colors.grey),
                        )
                      : Text(
                          _handle != null ? '@${_handle!}' : 'Not set',
                          style: const TextStyle(color: Colors.grey),
                        ),
                  trailing: IconButton(
                    icon: const Icon(Icons.edit, color: Colors.white70),
                    onPressed: _isHandleLoading
                        ? null
                        : () {
                            _showEditHandleDialog();
                          },
                  ),
                ),
                const Divider(color: Colors.white10),
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.redAccent),
                  title: const Text(
                    'Logout',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                  onTap: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: Colors.grey[900],
                        title: const Text(
                          'Logout?',
                          style: TextStyle(color: Colors.white),
                        ),
                        content: const Text(
                          'Do you really want to log out?',
                          style: TextStyle(color: Colors.grey),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.redAccent,
                            ),
                            child: const Text('Logout'),
                          ),
                        ],
                      ),
                    );

                    if (confirmed == true && context.mounted) {
                      await Supabase.instance.client.auth.signOut();
                    }
                  },
                ),
                const SizedBox(height: 24),
                // Privacy Section
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Privacy',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // Inkognito Mode
                ListTile(
                  leading: Icon(
                    Icons.visibility_off,
                    color: _isIncognito ? Colors.deepPurple : Colors.white70,
                  ),
                  title: const Text(
                    'Incognito Mode',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    _getIncognitoStatusText(),
                    style: TextStyle(
                      color: _isIncognito
                          ? Colors.deepPurple[200]
                          : Colors.grey,
                    ),
                  ),
                  trailing: Switch(
                    value: _isIncognito,
                    activeColor: Colors.deepPurple,
                    onChanged: (value) {
                      if (value) {
                        _showIncognitoDialog();
                      } else {
                        _updateIncognitoStatus(false, null);
                      }
                    },
                  ),
                ),

                const Divider(color: Colors.white10),

                ListTile(
                  leading: const Icon(Icons.shield, color: Color(0xFF4DD0E1)),
                  title: const Text(
                    'Safe Zones',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    'Places where you don\'t want to be visible',
                    style: TextStyle(color: Colors.grey),
                  ),
                  trailing: const Icon(
                    Icons.arrow_forward_ios,
                    color: Colors.grey,
                    size: 16,
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const SafeZonesScreen(),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),
                // App Info Section
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'App',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const ListTile(
                  leading: Icon(Icons.info_outline, color: Colors.white70),
                  title: Text('Version', style: TextStyle(color: Colors.white)),
                  subtitle: Text('1.0.0', style: TextStyle(color: Colors.grey)),
                ),
              ],
            ),
    );
  }
}
