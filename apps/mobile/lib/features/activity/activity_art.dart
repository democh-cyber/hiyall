import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../shared/widgets.dart';

class RefreshOrbit extends StatefulWidget {
  final bool loading;
  const RefreshOrbit({super.key, required this.loading});
  @override
  State<RefreshOrbit> createState() => RefreshOrbitState();
}

class RefreshOrbitState extends State<RefreshOrbit>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(RefreshOrbit oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.loading && !MediaQuery.disableAnimationsOf(context)) {
      controller.repeat();
    } else {
      controller.stop();
      controller.value = 0;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.loading ? 'Refreshing activity' : 'Pull to refresh activity',
    liveRegion: true,
    child: Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      child: SizedBox(
        width: 40,
        height: 40,
        child: AnimatedBuilder(
          animation: controller,
          builder: (_, _) => CustomPaint(
            painter: RefreshOrbitPainter(
              controller.value,
              Theme.of(context).brightness == Brightness.dark,
            ),
          ),
        ),
      ),
    ),
  );
}

class RefreshOrbitPainter extends CustomPainter {
  final double phase;
  final bool dark;
  const RefreshOrbitPainter(this.phase, this.dark);
  @override
  void paint(Canvas canvas, Size size) {
    final color = dark ? VibeColors.lime : const Color(0xff62802d);
    final center = size.center(Offset.zero);
    canvas.drawCircle(
      center,
      11,
      Paint()
        ..color = color.withValues(alpha: .35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawCircle(
      center +
          Offset(
            math.cos(phase * math.pi * 2) * 11,
            math.sin(phase * math.pi * 2) * 11,
          ),
      3,
      Paint()..color = color,
    );
    canvas.drawCircle(center, 2, Paint()..color = color.withValues(alpha: .55));
  }

  @override
  bool shouldRepaint(RefreshOrbitPainter old) =>
      phase != old.phase || dark != old.dark;
}

/// Offline, static vector art: a relaxed orbit rather than a notification banner.
class QuietOrbitPainter extends CustomPainter {
  final bool dark;
  const QuietOrbitPainter(this.dark);
  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width / 360, size.height / 240);
    canvas.save();
    canvas.translate(
      (size.width - 360 * scale) / 2,
      (size.height - 240 * scale) / 2,
    );
    canvas.scale(scale);
    final ink = dark ? VibeColors.lilac : VibeColors.ink;
    canvas.drawCircle(
      const Offset(180, 120),
      110,
      Paint()
        ..shader = RadialGradient(
          colors: [
            VibeColors.lilac.withValues(alpha: dark ? .055 : .12),
            Colors.transparent,
          ],
        ).createShader(const Rect.fromLTWH(70, 10, 220, 220)),
    );
    canvas.save();
    canvas.translate(180, 124);
    canvas.rotate(-.38);
    final line = Paint()
      ..color = ink.withValues(alpha: dark ? .25 : .22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8;
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 280, height: 130),
      line,
    );
    canvas.rotate(.82);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 240, height: 144),
      line,
    );
    canvas.restore();
    canvas.drawCircle(
      const Offset(104, 136),
      44,
      Paint()..color = VibeColors.peach,
    );
    final shape = Path()
      ..moveTo(157, 54)
      ..cubicTo(210, 30, 253, 77, 239, 127)
      ..cubicTo(234, 174, 195, 197, 151, 181)
      ..cubicTo(118, 159, 110, 81, 157, 54)
      ..close();
    canvas.drawPath(
      shape,
      Paint()
        ..shader = const LinearGradient(
          // RTL: physical (artwork)
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [VibeColors.lilac, Color(0xffbba2e4)],
        ).createShader(const Rect.fromLTWH(116, 42, 132, 146)),
    );
    canvas.save();
    canvas.clipPath(shape);
    for (var i = 0; i < 100; i++) {
      canvas.drawCircle(
        Offset(
          116 + ((i * 47) % 132).toDouble(),
          42 + ((i * 71) % 146).toDouble(),
        ),
        .65,
        Paint()..color = VibeColors.ink.withValues(alpha: .09),
      );
    }
    canvas.restore();
    final face = Paint()
      ..color = VibeColors.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      const Rect.fromLTWH(150, 105, 14, 8),
      .15,
      math.pi - .3,
      false,
      face,
    );
    canvas.drawArc(
      const Rect.fromLTWH(190, 105, 14, 8),
      .15,
      math.pi - .3,
      false,
      face,
    );
    canvas.drawArc(
      const Rect.fromLTWH(164, 123, 30, 19),
      .1,
      math.pi - .2,
      false,
      face,
    );
    canvas.drawCircle(
      const Offset(266, 77),
      12,
      Paint()..color = VibeColors.lime,
    );
    canvas.drawPath(
      starPath(const Offset(88, 64), 10, 4),
      Paint()..color = VibeColors.peach,
    );
    canvas.drawPath(
      starPath(const Offset(265, 170), 7, 2.5),
      Paint()..color = ink.withValues(alpha: .6),
    );
    canvas.drawCircle(
      const Offset(54, 142),
      2.5,
      Paint()..color = ink.withValues(alpha: .45),
    );
    canvas.drawCircle(
      const Offset(300, 128),
      2,
      Paint()..color = ink.withValues(alpha: .45),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(QuietOrbitPainter old) => dark != old.dark;
}
