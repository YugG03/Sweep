import 'dart:math';

import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:flutter/material.dart';

/// Round proximity gauge: 24 segments light up from blue to red as the signal
/// gets stronger, and a ripple spreads out on every pulse (beep).
/// It shows closeness only. Bluetooth signal strength cannot give direction.
class DetectorView extends StatefulWidget {
  const DetectorView({
    super.key,
    required this.heat,
    required this.color,
    required this.pulses,
    required this.title,
    required this.subtitle,
  });

  final double heat; // 0..1
  final Color color;
  final ValueListenable<int> pulses;
  final String title;
  final String subtitle;

  @override
  State<DetectorView> createState() => _DetectorViewState();
}

class _DetectorViewState extends State<DetectorView> with SingleTickerProviderStateMixin {
  static const _rippleMs = 900;
  late final AnimationController _ticker =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();
  final List<DateTime> _ripples = [];

  @override
  void initState() {
    super.initState();
    widget.pulses.addListener(_onPulse);
  }

  void _onPulse() => _ripples.add(DateTime.now());

  @override
  void didUpdateWidget(covariant DetectorView old) {
    super.didUpdateWidget(old);
    if (old.pulses != widget.pulses) {
      old.pulses.removeListener(_onPulse);
      widget.pulses.addListener(_onPulse);
    }
  }

  @override
  void dispose() {
    widget.pulses.removeListener(_onPulse);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      alignment: Alignment.center,
      children: [
        AnimatedBuilder(
          animation: _ticker,
          builder: (_, __) {
            final now = DateTime.now();
            _ripples.removeWhere((t) => now.difference(t).inMilliseconds > _rippleMs);
            return CustomPaint(
              size: Size.infinite,
              painter: _DetectorPainter(
                heat: widget.heat,
                color: widget.color,
                ripples: List.of(_ripples),
                now: now,
                rippleMs: _rippleMs,
                track: theme.colorScheme.outlineVariant,
              ),
            );
          },
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(color: widget.color, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(widget.subtitle, style: theme.textTheme.bodySmall),
          ],
        ),
      ],
    );
  }
}

class _DetectorPainter extends CustomPainter {
  _DetectorPainter({
    required this.heat,
    required this.color,
    required this.ripples,
    required this.now,
    required this.rippleMs,
    required this.track,
  });

  final double heat;
  final Color color;
  final List<DateTime> ripples;
  final DateTime now;
  final int rippleMs;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = min(size.width, size.height) / 2 - 10;

    // Soft glow that grows with proximity.
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withAlpha((40 + 60 * heat).round()), color.withAlpha(0)],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );

    // Faint guide rings.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = track.withAlpha(90);
    for (final f in [0.35, 0.58, 0.78]) {
      canvas.drawCircle(center, r * f, ring);
    }

    // 24-segment gauge over 270 degrees, opening at the bottom.
    const n = 24;
    final seg = 1.5 * pi / n;
    final lit = (heat * n).round();
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10;
    for (var i = 0; i < n; i++) {
      arc.color = i < lit
          ? Color.lerp(Colors.blue, Colors.red, i / (n - 1))!
          : track.withAlpha(80);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        0.75 * pi + i * seg + 0.02,
        seg - 0.04,
        false,
        arc,
      );
    }

    // Ripples, one per pulse.
    for (final t in ripples) {
      final age = now.difference(t).inMilliseconds / rippleMs;
      if (age >= 1) continue;
      canvas.drawCircle(
        center,
        r * 0.74 * (0.12 + 0.88 * age),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = color.withAlpha(((1 - age) * 170).round()),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DetectorPainter old) => true;
}
