import 'dart:async';
import 'dart:math' show cos, pi, sin, sqrt;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'safe_zones_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.onRadiusChanged});

  /// Called when the user saves a new visibility radius (kRing 1–3).
  final void Function(int k)? onRadiusChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isIncognito = false;
  DateTime? _incognitoUntil;
  String? _handle;
  String? _avatarUrl;
  bool _isHandleLoading = true;
  bool _isLoading = true;
  bool _isUploadingAvatar = false;
  Timer? _updateTimer;
  int _visibilityRadius = 2;
  DateTime? _radiusCooldownUntil;
  Timer? _cooldownTimer;

  static const _kRadiusCooldown = Duration(minutes: 15);

  bool get _isCooldownActive =>
      _radiusCooldownUntil != null &&
      DateTime.now().isBefore(_radiusCooldownUntil!);

  void _startCooldownTimer() {
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!_isCooldownActive) {
        _cooldownTimer?.cancel();
        setState(() => _radiusCooldownUntil = null);
      } else {
        setState(() {});
      }
    });
  }

  String _cooldownLabel() {
    if (!_isCooldownActive) return '';
    final remaining = _radiusCooldownUntil!.difference(DateTime.now());
    final m = remaining.inMinutes;
    final s = remaining.inSeconds.remainder(60);
    return m > 0 ? 'Locked — ${m}m ${s}s' : 'Locked — ${s}s';
  }

  @override
  void initState() {
    super.initState();
    _loadIncognitoStatus();
    _loadHandle();
    _loadVisibilityRadius();
    _loadAvatar();

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
    _cooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAvatar() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final resp = await Supabase.instance.client
          .from('profiles')
          .select('avatar_url')
          .eq('id', userId)
          .single();
      if (mounted) setState(() => _avatarUrl = resp['avatar_url'] as String?);
    } catch (e) {
      debugPrint('[settings] Error loading avatar: $e');
    }
  }

  Future<void> _pickAndUploadAvatar() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked == null) return;

    setState(() => _isUploadingAvatar = true);
    try {
      final bytes = await picked.readAsBytes();

      // ── Size guard: reject anything over 5 MB ─────────────────────────
      const maxBytes = 5 * 1024 * 1024; // 5 MB
      if (bytes.length > maxBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image is too large (max 5 MB).')),
          );
        }
        return;
      }

      // ── MIME guard: check magic bytes (JPEG FF D8 FF, PNG 89 50 4E 47) ─
      final isJpeg =
          bytes.length > 2 &&
          bytes[0] == 0xFF &&
          bytes[1] == 0xD8 &&
          bytes[2] == 0xFF;
      final isPng =
          bytes.length > 3 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47;
      if (!isJpeg && !isPng) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Only JPEG and PNG images are supported.'),
            ),
          );
        }
        return;
      }

      // image_picker always returns JPEG on iOS (HEIC is converted) — use a
      // fixed .jpg extension so the storage path is stable across uploads.
      // Note: bucket name is 'avatars', so the object path must NOT repeat it.
      final path = '$userId.jpg';

      await Supabase.instance.client.storage
          .from('avatars')
          .uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              upsert: true,
            ),
          );

      final rawUrl = Supabase.instance.client.storage
          .from('avatars')
          .getPublicUrl(path);
      // Append a cache-bust param so the new image loads immediately.
      final url = '$rawUrl?t=${DateTime.now().millisecondsSinceEpoch}';

      await Supabase.instance.client
          .from('profiles')
          .update({'avatar_url': url})
          .eq('id', userId);

      if (mounted) setState(() => _avatarUrl = url);
    } catch (e) {
      debugPrint('[settings] Avatar upload error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _isUploadingAvatar = false);
    }
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
          .select('is_incognito, incognito_until, avatar_url')
          .eq('id', userId)
          .single();

      if (mounted) {
        setState(() {
          _isIncognito = resp['is_incognito'] ?? false;
          final until = resp['incognito_until'];
          _incognitoUntil = until != null ? DateTime.parse(until) : null;
          _avatarUrl = resp['avatar_url'] as String?;

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

  // ── Visibility radius ────────────────────────────────────────────────────

  Future<void> _loadVisibilityRadius() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final resp = await Supabase.instance.client
          .from('profiles')
          .select('visibility_radius, visibility_radius_changed_at')
          .eq('id', userId)
          .single();
      if (mounted) {
        final changedAtRaw = resp['visibility_radius_changed_at'] as String?;
        DateTime? cooldownUntil;
        if (changedAtRaw != null) {
          final changedAt = DateTime.parse(changedAtRaw).toLocal();
          final candidate = changedAt.add(_kRadiusCooldown);
          if (candidate.isAfter(DateTime.now())) cooldownUntil = candidate;
        }
        setState(() {
          _visibilityRadius = (resp['visibility_radius'] as int?) ?? 2;
          _radiusCooldownUntil = cooldownUntil;
        });
        if (cooldownUntil != null) _startCooldownTimer();
      }
    } catch (e) {
      debugPrint('[settings] Error loading visibility_radius: $e');
    }
  }

  Future<void> _saveVisibilityRadius(int k) async {
    if (_isCooldownActive) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final now = DateTime.now().toUtc();
      await Supabase.instance.client
          .from('profiles')
          .update({
            'visibility_radius': k,
            'visibility_radius_changed_at': now.toIso8601String(),
          })
          .eq('id', userId);
      widget.onRadiusChanged?.call(k);
      if (mounted) {
        setState(
          () => _radiusCooldownUntil = now.toLocal().add(_kRadiusCooldown),
        );
        _startCooldownTimer();
      }
    } catch (e) {
      debugPrint('[settings] Error saving visibility_radius: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving radius: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    final email = user?.email ?? 'Nicht angemeldet';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'settings.',
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const SizedBox(height: 20),
                // ── Visibility Section ──────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Visibility',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      GestureDetector(
                        onPanUpdate: _isCooldownActive
                            ? null
                            : (details) {
                                final dx = details.localPosition.dx - 110;
                                final dy = details.localPosition.dy - 110;
                                final dist = sqrt(dx * dx + dy * dy);
                                final newK = dist < 40
                                    ? 1
                                    : dist < 70
                                    ? 2
                                    : 3;
                                if (newK != _visibilityRadius) {
                                  HapticFeedback.selectionClick();
                                  setState(() => _visibilityRadius = newK);
                                }
                              },
                        onPanEnd: _isCooldownActive
                            ? null
                            : (_) => _saveVisibilityRadius(_visibilityRadius),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 220,
                              height: 220,
                              child: CustomPaint(
                                painter: _RadiusSelectorPainter(
                                  kRing: _visibilityRadius,
                                  locked: _isCooldownActive,
                                ),
                              ),
                            ),
                            if (_isCooldownActive)
                              const Icon(
                                Icons.lock,
                                color: Colors.white38,
                                size: 32,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isCooldownActive
                            ? _cooldownLabel()
                            : _radiusLabel(_visibilityRadius),
                        style: TextStyle(
                          color: _isCooldownActive
                              ? Colors.orange[400]
                              : Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isCooldownActive
                            ? 'You can adjust your visibility range again after the cooldown.'
                            : 'Drag outward or inward to adjust — friends with a smaller radius may not see you.',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                // ── Privacy Section ─────────────────────────────────────
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
                    activeThumbColor: Colors.deepPurple,
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
                // ── Account Section ─────────────────────────────────────
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
                // Avatar
                ListTile(
                  leading: _isUploadingAvatar
                      ? const SizedBox(
                          width: 40,
                          height: 40,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFFFF8800),
                          ),
                        )
                      : GestureDetector(
                          onTap: _pickAndUploadAvatar,
                          child: CircleAvatar(
                            radius: 20,
                            backgroundColor: const Color(0xFF311B00),
                            backgroundImage: _avatarUrl != null
                                ? NetworkImage(_avatarUrl!)
                                : null,
                            child: _avatarUrl == null
                                ? const Icon(
                                    Icons.person,
                                    color: Color(0xFFFF8A00),
                                    size: 22,
                                  )
                                : null,
                          ),
                        ),
                  title: const Text(
                    'Profile Picture',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    _avatarUrl != null
                        ? 'Tap photo to change'
                        : 'Tap to upload a photo',
                    style: const TextStyle(color: Colors.grey),
                  ),
                  trailing: _avatarUrl == null
                      ? TextButton(
                          onPressed: _isUploadingAvatar
                              ? null
                              : _pickAndUploadAvatar,
                          child: const Text(
                            'Upload',
                            style: TextStyle(color: Color(0xFFFF8800)),
                          ),
                        )
                      : null,
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
                const ListTile(
                  leading: Icon(Icons.info_outline, color: Colors.white70),
                  title: Text('Version', style: TextStyle(color: Colors.white)),
                  subtitle: Text('1.0.0', style: TextStyle(color: Colors.grey)),
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
              ],
            ),
    );
  }

  String _radiusLabel(int k) {
    switch (k) {
      case 1:
        return 'Close — ~500m';
      case 3:
        return 'Wide — ~1km';
      default:
        return 'Normal — ~800m';
    }
  }
}

// ── Radius Selector Painter ───────────────────────────────────────────────────

class _RadiusSelectorPainter extends CustomPainter {
  final int kRing;
  final bool locked;

  const _RadiusSelectorPainter({required this.kRing, this.locked = false});

  // Returns which ring (0=center, 1=ring1, 2=ring2, 3=ring3) a hex at axial
  // coords (q, r) belongs to. Uses the Chebyshev distance on the cube grid.
  static int _ringOf(int q, int r) {
    final s = -q - r;
    return ([q.abs(), r.abs(), s.abs()].reduce((a, b) => a > b ? a : b));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final side = size.shortestSide * 0.085;
    final spacingX = side * 1.7320508; // sqrt(3)
    final spacingY = side * 1.5;

    // Draw a 7×7 axial grid (kRing 0..3).
    for (var q = -3; q <= 3; q++) {
      for (var r = (-3 - q).clamp(-3, 3); r <= (3 - q).clamp(-3, 3); r++) {
        final ring = _ringOf(q, r);
        if (ring > 3) continue;

        final x = (q + r / 2) * spacingX;
        final y = r * spacingY;
        final cellCenter = center + Offset(x, y);

        final active = ring <= kRing;
        final isCore = ring == 0;

        Color fillColor;
        Color borderColor;

        if (isCore) {
          fillColor = locked
              ? const Color(0xFF555555)
              : const Color(0xFFFF8A00);
          borderColor = locked
              ? const Color(0xFF777777)
              : const Color(0xFFFF8A00);
        } else if (active) {
          // Fade from bright to dim as ring increases.
          final opacity = locked ? 0.25 : (1.0 - (ring - 1) * 0.25);
          fillColor = Color.fromRGBO(
            (0x31 + ((0xFF - 0x31) * opacity * 0.18)).round(),
            0x1B,
            0x00,
            1,
          );
          borderColor = Color.fromRGBO(
            0xFF,
            (0x8A * opacity).round(),
            0x00,
            opacity * 0.85 + 0.15,
          );
        } else {
          fillColor = const Color(0xFF111111);
          borderColor = Colors.white10;
        }

        final path = _hexPath(cellCenter, side);
        canvas.drawPath(path, Paint()..color = fillColor);
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = isCore ? 4 : 1.5
            ..color = borderColor,
        );
      }
    }
  }

  Path _hexPath(Offset center, double side) {
    final path = Path();
    for (var i = 0; i < 6; i++) {
      final angle = pi / 6 + i * pi / 3;
      final pt = Offset(
        center.dx + side * cos(angle),
        center.dy + side * sin(angle),
      );
      if (i == 0)
        path.moveTo(pt.dx, pt.dy);
      else
        path.lineTo(pt.dx, pt.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _RadiusSelectorPainter old) =>
      old.kRing != kRing || old.locked != locked;
}
