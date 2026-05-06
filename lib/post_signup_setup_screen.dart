import 'dart:math' show cos, pi, sin, sqrt;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'safe_zones_screen.dart';

class PostSignupSetupScreen extends StatefulWidget {
  final VoidCallback onDone;

  const PostSignupSetupScreen({super.key, required this.onDone});

  @override
  State<PostSignupSetupScreen> createState() => _PostSignupSetupScreenState();
}

class _PostSignupSetupScreenState extends State<PostSignupSetupScreen> {
  int _step = 0;
  int _visibilityRadius = 2;
  bool _isSaving = false;
  bool _safeZoneAdded = false;

  Future<void> _saveRadiusAndNext() async {
    setState(() => _isSaving = true);
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        await Supabase.instance.client
            .from('profiles')
            .update({'visibility_radius': _visibilityRadius})
            .eq('id', userId);
      }
    } catch (e) {
      debugPrint('[setup] Error saving visibility_radius: $e');
    }
    if (mounted) {
      setState(() {
        _isSaving = false;
        _step = 1;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          transitionBuilder: (child, anim) {
            final offset =
                Tween<Offset>(
                  begin: const Offset(1, 0),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                );
            return SlideTransition(position: offset, child: child);
          },
          child: _step == 0
              ? _VisibilityStep(
                  key: const ValueKey('visibility'),
                  visibilityRadius: _visibilityRadius,
                  isSaving: _isSaving,
                  onRadiusChanged: (k) => setState(() => _visibilityRadius = k),
                  onNext: _saveRadiusAndNext,
                )
              : _SafeZoneStep(
                  key: const ValueKey('safezone'),
                  safeZoneAdded: _safeZoneAdded,
                  onSafeZoneAdded: () => setState(() => _safeZoneAdded = true),
                  onDone: widget.onDone,
                ),
        ),
      ),
    );
  }
}

// ─── Step 0: Visibility Radius ────────────────────────────────────────────────

class _VisibilityStep extends StatelessWidget {
  final int visibilityRadius;
  final bool isSaving;
  final ValueChanged<int> onRadiusChanged;
  final VoidCallback onNext;

  const _VisibilityStep({
    super.key,
    required this.visibilityRadius,
    required this.isSaving,
    required this.onRadiusChanged,
    required this.onNext,
  });

  String _label(int k) {
    switch (k) {
      case 1:
        return 'Close — ~500m';
      case 3:
        return 'Wide — ~1km';
      default:
        return 'Normal — ~800m';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 48),
          const Text(
            'Set your radar range.',
            style: TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              height: 1.15,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'How far should hang look for friends?\nDrag inward or outward on the hex to adjust.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 15,
              height: 1.5,
            ),
          ),
          const Spacer(),
          Center(
            child: GestureDetector(
              onPanUpdate: (details) {
                final dx = details.localPosition.dx - 110;
                final dy = details.localPosition.dy - 110;
                final dist = sqrt(dx * dx + dy * dy);
                final newK = dist < 40
                    ? 1
                    : dist < 70
                    ? 2
                    : 3;
                if (newK != visibilityRadius) {
                  HapticFeedback.selectionClick();
                  onRadiusChanged(newK);
                }
              },
              child: SizedBox(
                width: 220,
                height: 220,
                child: CustomPaint(
                  painter: _SetupRadiusPainter(kRing: visibilityRadius),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              _label(visibilityRadius),
              style: const TextStyle(
                color: Color(0xFFFF8A00),
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Friends with a smaller radius may not see you.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: isSaving ? null : onNext,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF8C00),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: isSaving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Text(
                      'Next',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 36),
        ],
      ),
    );
  }
}

// ─── Step 1: Safe Zones ───────────────────────────────────────────────────────

class _SafeZoneStep extends StatelessWidget {
  final bool safeZoneAdded;
  final VoidCallback onSafeZoneAdded;
  final VoidCallback onDone;

  const _SafeZoneStep({
    super.key,
    required this.safeZoneAdded,
    required this.onSafeZoneAdded,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 48),
          const Text(
            'Protect your home.',
            style: TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              height: 1.15,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Safe Zones are places where your radar pauses automatically — your home, office, anywhere you want to be invisible.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 15,
              height: 1.5,
            ),
          ),
          const Spacer(),
          Center(
            child: Icon(
              safeZoneAdded ? Icons.shield : Icons.shield_outlined,
              color: safeZoneAdded ? const Color(0xFF4DD0E1) : Colors.white24,
              size: 100,
            ),
          ),
          const SizedBox(height: 24),
          if (safeZoneAdded)
            Center(
              child: Text(
                'Safe Zone added ✓',
                style: const TextStyle(
                  color: Color(0xFF4DD0E1),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            Center(
              child: TextButton.icon(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SafeZonesScreen()),
                  );
                  onSafeZoneAdded();
                },
                icon: const Icon(
                  Icons.add_location_alt,
                  color: Color(0xFF4DD0E1),
                ),
                label: const Text(
                  'Set up a Safe Zone',
                  style: TextStyle(color: Color(0xFF4DD0E1), fontSize: 15),
                ),
              ),
            ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: onDone,
              style: ElevatedButton.styleFrom(
                backgroundColor: safeZoneAdded
                    ? const Color(0xFF4DD0E1)
                    : const Color(0xFF222222),
                foregroundColor: safeZoneAdded ? Colors.black : Colors.white54,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: Text(
                safeZoneAdded ? "All done — let's go!" : 'Skip for now',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(height: 36),
        ],
      ),
    );
  }
}

// ─── Hex Painter (same logic as settings_screen._RadiusSelectorPainter) ───────

class _SetupRadiusPainter extends CustomPainter {
  final int kRing;
  const _SetupRadiusPainter({required this.kRing});

  static int _ringOf(int q, int r) {
    final s = -q - r;
    return [q.abs(), r.abs(), s.abs()].reduce((a, b) => a > b ? a : b);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final side = size.shortestSide * 0.085;
    final spacingX = side * 1.7320508;
    final spacingY = side * 1.5;

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
          fillColor = const Color(0xFFFF8A00);
          borderColor = const Color(0xFFFF8A00);
        } else if (active) {
          final opacity = 1.0 - (ring - 1) * 0.25;
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
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _SetupRadiusPainter old) => old.kRing != kRing;
}
