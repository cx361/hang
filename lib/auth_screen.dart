import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLogin = true;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleAuth() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter email and password';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (_isLogin) {
        // Login
        await Supabase.instance.client.auth.signInWithPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      } else {
        // Signup
        await Supabase.instance.client.auth.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );

        // Supabase often requires email confirmation which does not create
        // a session immediately. If there's no current session, inform the
        // user to check their email and stop the loading spinner.
        final session = Supabase.instance.client.auth.currentSession;
        if (session == null) {
          if (!mounted) return;
          setState(() {
            _isLoading = false;
            _errorMessage =
                'Please confirm your email. Check your inbox for a confirmation link.';
          });
          return;
        }
      }
      // Navigation wird von main.dart übernommen (auth listener)
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onBg = isDark ? Colors.white : Colors.black87;
    final subtle = isDark ? Colors.white60 : Colors.black54;
    final borderColor = isDark ? Colors.white30 : Colors.black26;
    final fillColor = isDark
        ? Colors.white.withAlpha(10)
        : Colors.grey.shade100;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo/Title
                const Text(
                  'hang.',
                  style: TextStyle(
                    color: Color(0xFFFF8800),
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _isLogin ? 'Welcome back' : 'Create your account',
                  style: TextStyle(color: subtle, fontSize: 18),
                ),
                const SizedBox(height: 48),

                // Email Field
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  style: TextStyle(color: onBg),
                  decoration: InputDecoration(
                    labelText: 'Email',
                    labelStyle: TextStyle(color: subtle),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: borderColor),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: const BorderSide(color: Color(0xFFFF8800)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    fillColor: fillColor,
                  ),
                ),
                const SizedBox(height: 16),

                // Password Field
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  autocorrect: false,
                  style: TextStyle(color: onBg),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    labelStyle: TextStyle(color: subtle),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: borderColor),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: const BorderSide(color: Color(0xFFFF8800)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    fillColor: fillColor,
                  ),
                  onSubmitted: (_) => _handleAuth(),
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

                // Auth Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _handleAuth,
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
                        : Text(
                            _isLogin ? 'Login' : 'Sign Up',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 16),

                // Toggle Login/Signup
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isLogin = !_isLogin;
                      _errorMessage = null;
                    });
                  },
                  child: Text(
                    _isLogin
                        ? 'No account yet? Sign Up'
                        : 'Already have an account? Login',
                    style: TextStyle(color: subtle),
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
