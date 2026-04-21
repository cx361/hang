import 'package:flutter/material.dart';

class GlowWaveOverlay extends StatefulWidget {
  final bool isActive;
  final Color color;
  final Duration duration;

  const GlowWaveOverlay({
    super.key,
    this.isActive = false,
    this.color = const Color(0xFFFF8800),
    this.duration = const Duration(seconds: 2),
  });

  @override
  State<GlowWaveOverlay> createState() => _GlowWaveOverlayState();
}

class _GlowWaveOverlayState extends State<GlowWaveOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final activeColor = widget.isActive ? widget.color : Colors.grey;
          return CustomPaint(
            painter: _GlowWavePainter(
              progress: _controller.value,
              color: activeColor,
            ),
          );
        },
      ),
    );
  }
}

class _GlowWavePainter extends CustomPainter {
  final double progress;
  final Color color;

  _GlowWavePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide * 0.5;
    final radius = maxRadius * (0.2 + 0.8 * progress);
    final alpha = ((1.0 - progress) * 0.45 * 255).round().clamp(0, 255);

    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color.withAlpha(alpha), color.withAlpha(0)],
        stops: const [0.55, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..blendMode = BlendMode.plus
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24);
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant _GlowWavePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
