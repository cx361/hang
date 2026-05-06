import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_screen.dart';
import 'post_signup_setup_screen.dart';
import 'profile_setup_screen.dart';
import 'main.dart';

/// Manages authentication state and routing
class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  User? _user;
  bool _hasProfile = false;
  bool _isLoading = true;
  bool _needsSetup = false;

  @override
  void initState() {
    super.initState();
    _checkAuthState();

    // Listen to auth state changes
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final AuthChangeEvent event = data.event;
      if (event == AuthChangeEvent.signedIn) {
        _checkAuthState();
      } else if (event == AuthChangeEvent.signedOut) {
        setState(() {
          _user = null;
          _hasProfile = false;
          _isLoading = false;
        });
      }
    });
  }

  Future<void> _checkAuthState() async {
    final session = Supabase.instance.client.auth.currentSession;
    final user = session?.user;

    if (user == null) {
      setState(() {
        _user = null;
        _hasProfile = false;
        _isLoading = false;
      });
      return;
    }

    // Check if user has a profile
    try {
      final profile = await Supabase.instance.client
          .from('profiles')
          .select('id, handle')
          .eq('id', user.id)
          .maybeSingle();

      if (!mounted) return;

      setState(() {
        _user = user;
        _hasProfile = profile != null;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[AuthWrapper] Error checking profile: $e');
      if (!mounted) return;
      setState(() {
        _user = user;
        _hasProfile = false;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SplashScreen();
    }

    // Not logged in → AuthScreen
    if (_user == null) {
      return const AuthScreen();
    }

    // Logged in but no profile → ProfileSetupScreen
    if (!_hasProfile) {
      return ProfileSetupScreen(
        onProfileCreated: () {
          // Brand-new account: show post-signup setup before the main app.
          setState(() {
            _hasProfile = true;
            _needsSetup = true;
          });
        },
      );
    }

    // Freshly created account → post-signup setup
    if (_needsSetup) {
      return PostSignupSetupScreen(
        onDone: () => setState(() => _needsSetup = false),
      );
    }

    // Logged in with profile → Main App
    return const HangApp();
  }
}
