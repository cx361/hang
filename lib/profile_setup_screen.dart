import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProfileSetupScreen extends StatefulWidget {
  final VoidCallback onProfileCreated;

  const ProfileSetupScreen({super.key, required this.onProfileCreated});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _handleController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _handleController.dispose();
    super.dispose();
  }

  Future<void> _createProfile() async {
    var handle = _handleController.text.trim().toLowerCase();
    // Remove optional leading @ if the user typed it
    handle = handle.replaceFirst(RegExp(r'^@+'), '');

    // Validate handle
    if (handle.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a handle';
      });
      return;
    }

    // Handle validation: force lowercase and allow a-z, 0-9, dot, underscore, hyphen
    if (!RegExp(r'^[a-z0-9\._-]+$').hasMatch(handle)) {
      setState(() {
        _errorMessage =
            'Handle may only contain lowercase letters, numbers, dot, underscore and hyphen';
      });
      return;
    }

    if (handle.length < 3) {
      setState(() {
        _errorMessage = 'Handle must be at least 3 characters long';
      });
      return;
    }

    if (handle.length > 20) {
      setState(() {
        _errorMessage = 'Handle may not exceed 20 characters';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        throw Exception('No user logged in');
      }

      // Check if handle already exists
      final existing = await Supabase.instance.client
          .from('profiles')
          .select('id')
          .eq('handle', handle)
          .maybeSingle();

      if (existing != null) {
        if (!mounted) return;
        setState(() {
          _errorMessage = 'This handle is already taken';
          _isLoading = false;
        });
        return;
      }

      // Create profile
      await Supabase.instance.client.from('profiles').insert({
        'id': user.id,
        'handle': handle,
        'created_at': DateTime.now().toIso8601String(),
      });

      if (!mounted) return;

      // Notify parent that profile was created
      widget.onProfileCreated();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Error creating profile: ${e.message}';
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'An error occurred: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Title
                const Text(
                  'Choose your handle',
                  style: TextStyle(
                    color: Color(0xFFFF8800),
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This is how others will find you',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 48),

                // Handle Field
                TextField(
                  controller: _handleController,
                  autocorrect: false,
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                  decoration: InputDecoration(
                    prefixText: '@',
                    prefixStyle: const TextStyle(
                      color: Color(0xFFFF8800),
                      fontSize: 18,
                    ),
                    hintText: 'username',
                    hintStyle: const TextStyle(color: Colors.white30),
                    enabledBorder: OutlineInputBorder(
                      borderSide: const BorderSide(color: Colors.white30),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: const BorderSide(color: Color(0xFFFF8800)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    fillColor: Colors.white.withAlpha(10),
                  ),
                  onSubmitted: (_) => _createProfile(),
                ),
                const SizedBox(height: 12),

                // Info Text
                const Text(
                  'Only lowercase letters, numbers, dot (.), underscore (_) and hyphen (-) (3-20 characters)',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

                // Error Message
                if (_errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withAlpha(25),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withAlpha(76)),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // Create Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _createProfile,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF8800),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text(
                            'Create profile',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
