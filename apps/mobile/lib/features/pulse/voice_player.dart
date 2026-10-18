import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/voice.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/press_scale.dart';

/// Bars for a clip: the same ones every time for the same [seed], so a voice note does not change shape between
/// two looks. The server sends no loudness, so this is a drawing, not a measurement.
List<double> waveFor(String seed, int count) {
  var h = 0x811c9dc5;
  for (final c in seed.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  final out = <double>[];
  var x = h == 0 ? 1 : h;
  for (var i = 0; i < count; i++) {
    x ^= (x << 13) & 0xffffffff;
    x ^= x >> 17;
    x ^= (x << 5) & 0xffffffff;
    // A gentle swell so it reads as speech rather than noise.
    final swell = .55 + .45 * (1 - ((i / (count - 1)) * 2 - 1).abs());
    out.add((.2 + .8 * ((x & 0xffff) / 0xffff)) * swell);
  }
  return out;
}

/// A waveform-like bar: [bars] (0 to 1 each) with the part before [progress] drawn in [played] and the rest in
/// [rest]. It fills from the reading direction's start.
class WaveBars extends StatelessWidget {
  final List<double> bars;
  final double progress;
  final Color played, rest;
  final double height;
  const WaveBars({
    super.key,
    required this.bars,
    required this.progress,
    required this.played,
    required this.rest,
    this.height = 36,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.fromHeight(height),
    painter: _WavePainter(
      bars,
      progress.clamp(0.0, 1.0),
      played,
      rest,
      Directionality.of(context),
    ),
  );
}

class _WavePainter extends CustomPainter {
  final List<double> bars;
  final double progress;
  final Color played, rest;
  final TextDirection direction;
  _WavePainter(
    this.bars,
    this.progress,
    this.played,
    this.rest,
    this.direction,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty || size.width <= 0) return;
    const gap = 3.0;
    final slot = size.width / bars.length;
    final w = (slot - gap).clamp(1.5, 6.0);
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars.length; i++) {
      final fromStart = (i + .5) / bars.length;
      final x = direction == TextDirection.rtl
          ? size.width - slot * (i + .5)
          : slot * (i + .5);
      final h = (size.height * bars[i]).clamp(4.0, size.height);
      paint
        ..strokeWidth = w
        ..color = fromStart <= progress ? played : rest;
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.progress != progress ||
      old.played != played ||
      old.rest != rest ||
      old.bars != bars ||
      old.direction != direction;
}

/// Plays one voice clip: a play and pause button, a waveform-like bar that fills as it plays (tap it to jump),
/// and the length. Nothing plays until it is tapped; only one clip plays at a time in the whole app, and the
/// clip stops when this widget leaves the screen (scrolled away or its screen closed).
class VoicePlayerBar extends ConsumerStatefulWidget {
  /// Unique per clip (the media id; `draft` for a recording not yet posted).
  final String id;
  final ClipSource source;

  /// The clip's length from the server (or the recorder), shown until the player reports its own.
  final Duration duration;

  /// Who spoke, for screen readers: "Voice note from Niko".
  final String label;

  /// Light controls on a dark picture (the story viewer).
  final bool onDark;
  const VoicePlayerBar({
    super.key,
    required this.id,
    required this.source,
    required this.duration,
    this.label = 'Voice note',
    this.onDark = false,
  });

  @override
  ConsumerState<VoicePlayerBar> createState() => _VoicePlayerBarState();
}

class _VoicePlayerBarState extends ConsumerState<VoicePlayerBar> {
  late final ClipPlayback playback = ref.read(clipPlaybackProvider);
  late final String _id = widget.id;

  @override
  void dispose() {
    // A card scrolled out of sight or a closed screen stops its clip; another clip is left alone.
    playback.release(_id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final fg = widget.onDark ? Colors.white : t.text;
    final sub = widget.onDark ? Colors.white70 : t.textSecondary;
    return ListenableBuilder(
      listenable: playback,
      builder: (context, _) {
        final status = playback.statusOf(widget.id);
        final playing = status == ClipStatus.playing;
        final total = widget.duration;
        final position = playback.positionOf(widget.id);
        final active = status != ClipStatus.idle;
        final progress = total.inMilliseconds == 0
            ? 0.0
            : position.inMilliseconds / total.inMilliseconds;
        final failed = status == ClipStatus.failed;
        final loading = status == ClipStatus.loading;
        final time = active && !failed
            ? '${clipTime(position)} / ${clipTime(total)}'
            : clipTime(total);
        final playLabel = playing ? 'Pause voice note' : 'Play voice note';
        return Semantics(
          container: true,
          label: '${widget.label}, ${clipTime(total)}',
          value: failed
              ? 'Couldn’t play'
              : playing
              ? 'Playing, ${clipTime(position)}'
              : active
              ? 'Paused, ${clipTime(position)}'
              : null,
          child: Row(
            children: [
              PressScale(
                key: Key('voice-play-${widget.id}'),
                minHeight: 48,
                semanticLabel: failed ? 'Try playing again' : playLabel,
                onTap: () => playback.toggle(widget.id, widget.source),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: widget.onDark ? Colors.white : VibeColors.lime,
                    shape: BoxShape.circle,
                  ),
                  child: loading
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: VibeColors.ink,
                          ),
                        )
                      : Icon(
                          failed
                              ? Icons.refresh_rounded
                              : playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: VibeColors.ink,
                          size: 28,
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(
                      child: LayoutBuilder(
                        builder: (context, box) => GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (d) =>
                              _jump(d.localPosition.dx, box.maxWidth),
                          child: SizedBox(
                            height: 40,
                            child: WaveBars(
                              key: Key('voice-wave-${widget.id}'),
                              bars: waveFor(widget.id, 36),
                              progress: progress,
                              played: widget.onDark ? Colors.white : t.accent,
                              rest: widget.onDark ? Colors.white38 : t.hairline,
                              height: 36,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Text(
                      failed ? 'Couldn’t play. Tap to try again.' : time,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: failed ? fg : sub,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// A tap on the bar: starts a clip that is not playing, or moves the one that is.
  void _jump(double dx, double width) {
    if (width <= 0) return;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final fraction = ((rtl ? width - dx : dx) / width).clamp(0.0, 1.0);
    if (playback.activeId == widget.id &&
        playback.status != ClipStatus.failed) {
      playback.seek(
        widget.id,
        Duration(
          milliseconds: (widget.duration.inMilliseconds * fraction).round(),
        ),
      );
    } else {
      playback.toggle(widget.id, widget.source);
    }
  }
}
