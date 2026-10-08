import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

class ReadingWidth extends StatelessWidget {
  final Widget child;
  const ReadingWidth({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1060),
      child: child,
    ),
  );
}

class BrandMark extends StatelessWidget {
  final double size;
  const BrandMark({super.key, this.size = 44});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Kairova',
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: VibeColors.lime,
        borderRadius: BorderRadius.circular(size * .32),
      ),
      child: CustomPaint(painter: _MarkPainter()),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-.13);
    canvas.drawPath(
      starPath(Offset.zero, size.width * .33, size.width * .13),
      Paint()..color = VibeColors.ink,
    );
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => false;
}

Path starPath(Offset center, double outer, double inner) {
  final p = Path();
  for (var i = 0; i < 16; i++) {
    final a = i * math.pi / 8;
    final radius = i.isEven ? outer : inner;
    final pt = center + Offset(math.cos(a) * radius, math.sin(a) * radius);
    if (i == 0) {
      p.moveTo(pt.dx, pt.dy);
    } else {
      p.lineTo(pt.dx, pt.dy);
    }
  }
  return p..close();
}

class VibeTag extends StatelessWidget {
  final String text;
  final Color? color;
  final IconData? icon;
  const VibeTag(this.text, {super.key, this.color, this.icon});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: color ?? VibeColors.lime,
      borderRadius: BorderRadius.circular(100),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: VibeColors.ink),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            text.toUpperCase(),
            style: const TextStyle(
              color: VibeColors.ink,
              fontSize: 10,
              fontFamily: 'Manrope',
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
        ),
      ],
    ),
  );
}

class VibePanel extends StatelessWidget {
  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;
  const VibePanel({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(26),
  });
  @override
  Widget build(BuildContext context) => Material(
    animationDuration: VibeMotion.duration(context),
    color: color ?? Theme.of(context).colorScheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(VibeRadius.surface),
      side: BorderSide(
        color: color ?? Theme.of(context).colorScheme.outlineVariant,
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

class SectionTitle extends StatelessWidget {
  final String title, label;
  const SectionTitle(this.title, {super.key, this.label = ''});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 16),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        if (label.isNotEmpty)
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    ),
  );
}

class PageHeader extends StatelessWidget {
  final String eyebrow, title, subtitle;
  const PageHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        VibeTag(eyebrow),
        const SizedBox(height: 18),
        Text(
          title,
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
            fontSize: MediaQuery.sizeOf(context).width < 600 ? 36 : 44,
            height: 1.08,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}

class VibeHero extends StatelessWidget {
  final String tag, title, subtitle, art;
  final Widget? action;
  final bool dark;
  const VibeHero({
    super.key,
    required this.tag,
    required this.title,
    required this.subtitle,
    this.art = 'orbit',
    this.action,
    this.dark = false,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final split =
          box.maxWidth >= 690 &&
          MediaQuery.textScalerOf(context).scale(1) < 1.4;
      final fg = dark ? Colors.white : Theme.of(context).colorScheme.onSurface;
      final text = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          VibeTag(
            tag,
            color: art == 'chats' ? VibeColors.lilac : VibeColors.lime,
            icon: Icons.auto_awesome,
          ),
          const SizedBox(height: 24),
          Text(
            title,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontWeight: FontWeight.w700,
              fontSize: split ? 54 : 42,
              height: 1.03,
              letterSpacing: -2,
              color: fg,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            subtitle,
            style: TextStyle(
              color: dark
                  ? const Color(0xffd5d8cc)
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 14,
              height: 1.7,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 24), action!],
        ],
      );
      return VibePanel(
        color: dark ? VibeColors.ink : null,
        padding: EdgeInsets.all(split ? 34 : 24),
        child: split
            ? Row(
                children: [
                  Expanded(flex: 6, child: text),
                  const SizedBox(width: 28),
                  Expanded(flex: 5, child: VibeArt(kind: art, height: 290)),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  text,
                  const SizedBox(height: 26),
                  VibeArt(kind: art, height: 220),
                ],
              ),
      );
    },
  );
}

class TwoUp extends StatelessWidget {
  final Widget first, second;
  const TwoUp({super.key, required this.first, required this.second});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) =>
        box.maxWidth >= 600 && MediaQuery.textScalerOf(context).scale(1) < 1.4
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: first),
              const SizedBox(width: 16),
              Expanded(child: second),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [first, const SizedBox(height: 16), second],
          ),
  );
}

class FeatureTile extends StatelessWidget {
  final IconData icon;
  final String title, description;
  final Color color;
  final Widget? action;
  const FeatureTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.color = VibeColors.lilac,
    this.action,
  });
  @override
  Widget build(BuildContext context) => VibePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(icon, color: VibeColors.ink),
        ),
        const SizedBox(height: 18),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          description,
          style: TextStyle(
            fontSize: 13,
            height: 1.7,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (action != null) ...[const SizedBox(height: 16), action!],
      ],
    ),
  );
}

class EmptyCard extends StatelessWidget {
  final IconData icon;
  final String title, description;
  final Widget? action;
  const EmptyCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });
  @override
  Widget build(BuildContext context) => VibePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: VibeColors.lilac,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: VibeColors.ink, size: 23),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          description,
          style: TextStyle(
            height: 1.7,
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (action != null) ...[const SizedBox(height: 20), action!],
      ],
    ),
  );
}

class FailureCard extends StatelessWidget {
  final Object error;
  final VoidCallback retry;
  const FailureCard({super.key, required this.error, required this.retry});
  @override
  Widget build(BuildContext context) => EmptyCard(
    icon: Icons.cloud_off_rounded,
    title: 'Let’s try that again',
    description: error.toString(),
    action: OutlinedButton.icon(
      onPressed: retry,
      icon: const Icon(Icons.refresh),
      label: const Text('Retry'),
    ),
  );
}

/// Shows a short status line, replacing any earlier one so quick actions never
/// leave a queue of stale messages.
void showMessage(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));

/// Decorative, offline vector artwork. It contains no messages or user data.
class VibeArt extends StatelessWidget {
  final String kind;
  final double height;
  const VibeArt({super.key, this.kind = 'orbit', this.height = 240});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: CustomPaint(painter: _VibePainter(kind)),
      ),
    ),
  );
}

class _VibePainter extends CustomPainter {
  final String kind;
  const _VibePainter(this.kind);
  void bubble(
    Canvas c,
    Offset center,
    Size size,
    Color color,
    double angle,
    String label,
    Color fg,
  ) {
    c.save();
    c.translate(center.dx, center.dy);
    c.rotate(angle);
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: size.width,
      height: size.height,
    );
    c.drawRRect(
      RRect.fromRectAndRadius(rect.translate(0, 7), const Radius.circular(22)),
      Paint()..color = VibeColors.ink.withValues(alpha: .12),
    );
    c.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(22)),
      Paint()..color = color,
    );
    final t = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontFamily: 'SpaceGrotesk',
          fontWeight: FontWeight.w700,
          fontSize: size.height * .32,
          color: fg,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 26);
    t.paint(c, Offset(-t.width / 2, -t.height / 2));
    c.restore();
  }

  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    final bg = kind == 'chats'
        ? VibeColors.lilac
        : kind == 'bell'
        ? VibeColors.peach
        : kind == 'discover'
        ? VibeColors.mint
        : VibeColors.lilac;
    c.drawRect(Offset.zero & s, Paint()..color = bg);
    final grid = Paint()
      ..color = VibeColors.ink.withValues(alpha: .08)
      ..strokeWidth = 1;
    for (double x = -h; x < w + h; x += 32) {
      c.drawLine(Offset(x, 0), Offset(x + h, h), grid);
    }
    final stroke = Paint()
      ..color = VibeColors.ink.withValues(alpha: .26)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    c.drawOval(
      Rect.fromCenter(
        center: Offset(w * .52, h * .48),
        width: w * .85,
        height: h * .55,
      ),
      stroke,
    );
    c.save();
    c.translate(w * .52, h * .48);
    c.rotate(-.6);
    c.drawOval(
      Rect.fromCenter(center: Offset.zero, width: w * .85, height: h * .55),
      stroke,
    );
    c.restore();
    if (kind == 'chats') {
      bubble(
        c,
        Offset(w * .46, h * .34),
        Size(w * .64, h * .28),
        Colors.white,
        -.12,
        'hey, you.',
        VibeColors.ink,
      );
      bubble(
        c,
        Offset(w * .57, h * .64),
        Size(w * .67, h * .28),
        VibeColors.ink,
        .10,
        'good energy.',
        VibeColors.lime,
      );
      c.drawPath(
        starPath(Offset(w * .83, h * .25), h * .11, h * .045),
        Paint()..color = VibeColors.lime,
      );
      c.drawCircle(
        Offset(w * .2, h * .77),
        h * .073,
        Paint()..color = VibeColors.pink,
      );
    } else {
      final center = Offset(w * .51, h * .47), radius = h * .28;
      c.drawCircle(
        center + const Offset(0, 8),
        radius,
        Paint()..color = VibeColors.ink.withValues(alpha: .12),
      );
      c.drawCircle(
        center,
        radius,
        Paint()..color = kind == 'bell' ? VibeColors.lilac : VibeColors.lime,
      );
      c.drawCircle(
        center + Offset(-radius * .3, -radius * .16),
        radius * .07,
        Paint()..color = VibeColors.ink,
      );
      c.drawCircle(
        center + Offset(radius * .3, -radius * .16),
        radius * .07,
        Paint()..color = VibeColors.ink,
      );
      c.drawArc(
        Rect.fromCenter(
          center: center + Offset(0, radius * .08),
          width: radius * .75,
          height: radius * .6,
        ),
        0,
        math.pi,
        false,
        Paint()
          ..color = VibeColors.ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
      c.drawPath(
        starPath(Offset(w * .2, h * .2), h * .095, h * .038),
        Paint()..color = VibeColors.ink,
      );
      c.drawPath(
        starPath(Offset(w * .83, h * .58), h * .11, h * .043),
        Paint()
          ..color = kind == 'discover' ? VibeColors.lilac : VibeColors.pink,
      );
      bubble(
        c,
        Offset(w * .53, h * .83),
        Size(w * .59, h * .17),
        Colors.white,
        -.07,
        kind == 'bell'
            ? 'less noise.'
            : kind == 'discover'
            ? 'find your orbit.'
            : 'stay a little weird.',
        VibeColors.ink,
      );
    }
    for (final p in [
      Offset(w * .88, h * .11),
      Offset(w * .1, h * .51),
      Offset(w * .88, h * .88),
    ]) {
      c.drawCircle(p, 3, Paint()..color = VibeColors.ink);
    }
  }

  @override
  bool shouldRepaint(_VibePainter oldDelegate) => oldDelegate.kind != kind;
}

class VibeLoading extends StatelessWidget {
  const VibeLoading({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading your space',
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: VibePanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final width in [.3, .8, .65, .9])
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: FractionallySizedBox(
                  widthFactor: width,
                  child: Container(
                    height: width == .3 ? 44 : 18,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class IdentityCard extends StatelessWidget {
  final String name, username, bio, profession;
  final Widget action;
  const IdentityCard({
    super.key,
    required this.name,
    required this.username,
    required this.bio,
    required this.profession,
    required this.action,
  });
  @override
  Widget build(BuildContext context) => VibePanel(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const VibeArt(kind: 'discover', height: 170),
        Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: VibeColors.lilac,
                      borderRadius: BorderRadius.circular(26),
                    ),
                    child: Text(
                      name.isEmpty ? 'K' : name.characters.first,
                      style: const TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontSize: 36,
                        fontWeight: FontWeight.w700,
                        color: VibeColors.ink,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        Text(
                          '@$username',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              if (bio.isNotEmpty)
                Text(bio, style: Theme.of(context).textTheme.bodyLarge),
              if (profession.isNotEmpty) ...[
                const SizedBox(height: 14),
                VibeTag(profession, color: VibeColors.mint),
              ],
              const SizedBox(height: 24),
              action,
            ],
          ),
        ),
      ],
    ),
  );
}
