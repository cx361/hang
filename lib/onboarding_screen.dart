import 'dart:math' show cos, pi, sin;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Called when onboarding is complete — caller navigates away
typedef OnboardingDoneCallback = void Function();

class OnboardingScreen extends StatefulWidget {
  final OnboardingDoneCallback onDone;

  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Pulsing animation for slide 1
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  static const _slides = [
    _SlideData(
      title: 'Your Passive Radar',
      body:
          'hang runs silently in the background. Put your phone away and live your life. We\'ll find your friends so you don\'t have to.',
      icon: Icons.sensors,
      accent: Color(0xFFFF8C00),
    ),
    _SlideData(
      title: 'No Trails. No Tracking.',
      body:
          'We don\'t store or share your exact coordinates. hang uses blurred hexagonal sectors (~400m diameter). Using \'Significant Location Changes,\' we only update when you actually move — saving your battery and your privacy. No history is kept, only your most recent sector.',
      icon: Icons.shield_outlined,
      accent: Color(0xFFCCCCCC),
    ),
    _SlideData(
      title: 'The Magic Ping',
      body:
          'Forget \'Where are you?\' texts. hang notifies you when a friend enters your area (2 sectors away). A spontaneous coffee or a quick \'hello\' is just one notification away.',
      icon: Icons.notifications_active_outlined,
      accent: Color(0xFFFFD700),
    ),
    _SlideData(
      title: 'Your Sanctuary',
      body:
          'Your home is private. Create Safe Zones for your house or office. Once you enter, your radar pauses automatically. You vanish from the map until you leave.',
      icon: Icons.home_work_outlined,
      accent: Color(0xFF4ECDC4),
    ),
    _SlideData(
      title: 'Going Ghost',
      body:
          'Not in the mood? Toggle Incognito Mode to disappear from everyone\'s radar instantly. You stay in total control of when you want to be found.',
      icon: Icons.visibility_off_outlined,
      accent: Color(0xFF9B51E0),
    ),
    _SlideData(
      title: 'Ready to go?',
      body:
          'To make the magic happen, hang needs access to your location \'Always\'. We only wake up when you move. Ready to light up your radar?',
      icon: null,
      accent: Color(0xFFFF8C00),
      isFinal: true,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_onboarding', true);
    widget.onDone();
  }

  void _next() {
    if (_currentPage < _slides.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    } else {
      _finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _slides[_currentPage].accent;
    final isFinal = _slides[_currentPage].isFinal;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inactiveDot = isDark
        ? Colors.white24
        : Colors.black.withValues(alpha: 0.15);
    final skipColor = isDark
        ? Colors.white38
        : Colors.black.withValues(alpha: 0.35);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // Page content
            PageView.builder(
              controller: _pageController,
              onPageChanged: (i) => setState(() => _currentPage = i),
              itemCount: _slides.length,
              itemBuilder: (context, index) => _SlidePage(
                slide: _slides[index],
                pulseAnimation: _pulseAnimation,
              ),
            ),

            // Skip button (top right) — hidden on last slide
            if (!isFinal)
              Positioned(
                top: 12,
                right: 20,
                child: TextButton(
                  onPressed: _finish,
                  child: Text(
                    'Skip',
                    style: TextStyle(color: skipColor, fontSize: 14),
                  ),
                ),
              ),

            // Bottom: indicators + button
            Positioned(
              bottom: 40,
              left: 24,
              right: 24,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Page indicators
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(_slides.length, (i) {
                      final isActive = i == _currentPage;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: isActive ? 24 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: isActive ? accent : inactiveDot,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 32),

                  // CTA button
                  if (isFinal)
                    SizedBox(
                      width: double.infinity,
                      height: 58,
                      child: ElevatedButton(
                        onPressed: _finish,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF8C00),
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          'GET STARTED',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.4,
                          ),
                        ),
                      ),
                    )
                  else
                    GestureDetector(
                      onTap: _next,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'Continue',
                            style: TextStyle(
                              color: accent,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            Icons.arrow_forward_rounded,
                            color: accent,
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Slide page ───────────────────────────────────────────────────────────────

class _SlidePage extends StatelessWidget {
  final _SlideData slide;
  final Animation<double> pulseAnimation;

  const _SlidePage({required this.slide, required this.pulseAnimation});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 80, 32, 160),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Icon area
          if (slide.icon != null) ...[
            _IconWidget(slide: slide, pulseAnimation: pulseAnimation),
            const SizedBox(height: 52),
          ] else ...[
            _RadarAnimation(accent: slide.accent),
            const SizedBox(height: 52),
          ],

          // Title
          Text(
            slide.title,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 32,
              fontWeight: FontWeight.w800,
              height: 1.15,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 20),

          // Body
          Text(
            slide.body,
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
              fontSize: 16,
              height: 1.65,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

class _IconWidget extends StatelessWidget {
  final _SlideData slide;
  final Animation<double> pulseAnimation;

  const _IconWidget({required this.slide, required this.pulseAnimation});

  @override
  Widget build(BuildContext context) {
    // Only slide 0 (sensors icon / passive radar) gets the pulse animation
    final isPulse = slide.icon == Icons.sensors;

    return SizedBox(
      height: 100,
      child: isPulse
          ? AnimatedBuilder(
              animation: pulseAnimation,
              builder: (context, child) {
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    // Outer glow ring
                    Container(
                      width: 90 * pulseAnimation.value,
                      height: 90 * pulseAnimation.value,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: slide.accent.withValues(
                          alpha: (0.12 * (2 - pulseAnimation.value)).clamp(
                            0.0,
                            1.0,
                          ),
                        ),
                      ),
                    ),
                    Icon(slide.icon, color: slide.accent, size: 52),
                  ],
                );
              },
            )
          : Icon(slide.icon, color: slide.accent, size: 52),
    );
  }
}

// Animated radar rings for the final slide
class _RadarAnimation extends StatefulWidget {
  final Color accent;
  const _RadarAnimation({required this.accent});

  @override
  State<_RadarAnimation> createState() => _RadarAnimationState();
}

class _RadarAnimationState extends State<_RadarAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 100,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return CustomPaint(
            painter: _RadarPainter(
              progress: _ctrl.value,
              accent: widget.accent,
            ),
          );
        },
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double progress;
  final Color accent;

  const _RadarPainter({required this.progress, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final phase = (progress - i * 0.33).clamp(0.0, 1.0);
      final radius = phase * (size.shortestSide / 2);
      final opacity = (1.0 - phase).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = accent.withValues(alpha: opacity * 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(center, radius, paint);
    }
    // Sweep line
    final sweepAngle = progress * 2 * pi - pi / 2;
    final paint = Paint()
      ..color = accent.withValues(alpha: 0.9)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final end = Offset(
      center.dx + size.shortestSide / 2 * sin(sweepAngle + pi / 2),
      center.dy - size.shortestSide / 2 * cos(sweepAngle + pi / 2),
    );
    canvas.drawLine(center, end, paint);
    // Center dot
    canvas.drawCircle(center, 4, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.progress != progress;
}

// ─── Data model ──────────────────────────────────────────────────────────────

class _SlideData {
  final String title;
  final String body;
  final IconData? icon;
  final Color accent;
  final bool isFinal;

  const _SlideData({
    required this.title,
    required this.body,
    required this.icon,
    required this.accent,
    this.isFinal = false,
  });
}
