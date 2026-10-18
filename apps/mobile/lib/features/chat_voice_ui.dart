import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/chat/chat_attachment.dart' show SendStatus;
import '../core/chat/chat_av.dart';
import '../core/chat/chat_engine.dart';
import '../core/chat/chat_media.dart';
import '../core/chat/chat_voice_capture.dart';
import '../core/chat/chat_voice_player.dart';
import '../core/theme.dart';
import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';
import 'chat_av_providers.dart';
import 'chat_parts.dart';

// Voice messages in the conversation: the bubble that plays one, and the recording controls in the composer.
// Rules and limits: docs/security/14-encrypted-chat-attachments.md ("Voice messages and videos").

/// How wide a voice bubble's content is: 62 % of the screen, between 216 and 300 dp.
double chatVoiceWidth(BuildContext context) =>
    math.min(math.max(MediaQuery.sizeOf(context).width * .62, 216.0), 300.0);

// ------------------------------------------------------------- the bubble

/// A voice message in a bubble: a play/pause button, the waveform (tap or drag it to move through the
/// message), how long it is or how far it has played, and the speed (1x, 1.5x, 2x) while it is the active one.
/// Only one plays at a time: starting another stops this one.
class VoiceBody extends ConsumerWidget {
  final ChatMessage message;
  final ChatEngine engine;
  final String conversationId, peerName;
  final Color ink;
  const VoiceBody({
    super.key,
    required this.message,
    required this.engine,
    required this.conversationId,
    required this.peerName,
    required this.ink,
  });

  VoiceAttachment get voice => message.voice!;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(voicePlaybackProvider);
    return ListenableBuilder(
      listenable: playback,
      builder: (context, _) => _VoiceView(
        message: message,
        engine: engine,
        conversationId: conversationId,
        peerName: peerName,
        ink: ink,
        playback: playback,
      ),
    );
  }
}

class _VoiceView extends StatelessWidget {
  final ChatMessage message;
  final ChatEngine engine;
  final String conversationId, peerName;
  final Color ink;
  final VoicePlayback playback;
  const _VoiceView({
    required this.message,
    required this.engine,
    required this.conversationId,
    required this.peerName,
    required this.ink,
    required this.playback,
  });

  VoiceAttachment get voice => message.voice!;
  String get id => message.messageId;

  bool get _ready => message.status == SendStatus.sent && voice.uploaded;

  Future<void> _toggle() async {
    final media = engine.media;
    if (!_ready || media == null) return;
    await playback.toggle(
      id,
      () => media.plaintextBlob(conversationId, voice.spec),
    );
  }

  /// What is wrong with this message, in words, or null.
  String? _problem() {
    if (playback.statusOf(id) != VoiceStatus.failed) return null;
    final e = playback.error;
    if (e is ChatMediaFailure) {
      switch (e.problem) {
        case MediaProblem.unavailable:
          return 'This voice message has expired';
        case MediaProblem.corrupt:
          return 'Can’t play this voice message';
        case MediaProblem.network:
        case MediaProblem.other:
          return 'Couldn’t load. Tap to try again';
      }
    }
    return 'Couldn’t play. Tap to try again';
  }

  @override
  Widget build(BuildContext context) {
    final status = playback.statusOf(id);
    final active = playback.isActive(id) && status != VoiceStatus.failed;
    final total = Duration(milliseconds: voice.durationMs);
    final position = playback.positionOf(id);
    final fraction = total.inMilliseconds == 0
        ? 0.0
        : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final sending = message.status == SendStatus.sending;
    final failedSend = message.status == SendStatus.failed;
    final problem = _problem();
    final playing = status == VoiceStatus.playing;
    final loading = status == VoiceStatus.loading;
    final shown = active ? position : total;
    final who = message.mine
        ? 'Voice message you sent'
        : 'Voice message from $peerName';
    final label =
        '$who, ${clockOf(voice.durationMs)}'
        '${sending
            ? ', sending'
            : failedSend
            ? ', not sent'
            : playing
            ? ', playing'
            : active
            ? ', paused'
            : ''}${problem == null ? '' : ', $problem'}';
    final progress = sending ? engine.avProgress(id) : null;
    final canPlay = _ready && !loading;

    final button = _PlayButton(
      key: Key('voice-play-$id'),
      playing: playing,
      loading: loading || sending,
      enabled: canPlay || (playing),
      ink: ink,
      onTap: _toggle,
      label: playing ? 'Pause voice message' : 'Play voice message',
      progress: progress,
    );

    return Semantics(
      container: true,
      label: label,
      customSemanticsActions: {
        if (active)
          const CustomSemanticsAction(label: 'Change speed'): () =>
              unawaited(playback.cycleSpeed()),
      },
      child: SizedBox(
        width: chatVoiceWidth(context),
        child: Row(
          children: [
            button,
            const SizedBox(width: 8),
            Expanded(
              child: problem != null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: GestureDetector(
                        onTap: _toggle,
                        child: Text(
                          problem,
                          key: Key('voice-problem-$id'),
                          style: TextStyle(
                            color: ink,
                            fontSize: 13.5,
                            height: 1.3,
                          ),
                        ),
                      ),
                    )
                  : _Waveform(
                      key: Key('voice-wave-$id'),
                      wave: voice.wave,
                      fraction: fraction,
                      ink: ink,
                      onSeek: active
                          ? (f) => unawaited(
                              playback.seek(
                                id,
                                Duration(
                                  milliseconds: (f * total.inMilliseconds)
                                      .round(),
                                ),
                              ),
                            )
                          : null,
                    ),
            ),
            const SizedBox(width: 8),
            clampedChrome(
              context,
              Text(
                clockOf(shown.inMilliseconds),
                key: Key('voice-time-$id'),
                style: TextStyle(
                  color: ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (active) ...[
              const SizedBox(width: 4),
              _SpeedChip(
                key: Key('voice-speed-$id'),
                speed: playback.speed,
                ink: ink,
                onTap: () => unawaited(playback.cycleSpeed()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool playing, loading, enabled;
  final Color ink;
  final VoidCallback onTap;
  final String label;
  final dynamic progress;
  const _PlayButton({
    super.key,
    required this.playing,
    required this.loading,
    required this.enabled,
    required this.ink,
    required this.onTap,
    required this.label,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return PressScale(
      onTap: enabled ? onTap : null,
      semanticLabel: label,
      pressedScale: .92,
      borderRadius: BorderRadius.circular(24),
      child: SizedBox(
        width: ChatMetrics.hit,
        height: ChatMetrics.hit,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ink.withValues(alpha: t.isDark ? .22 : .16),
            ),
            child: loading
                ? Padding(
                    padding: const EdgeInsets.all(11),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: ink,
                    ),
                  )
                : Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 26,
                    color: ink,
                  ),
          ),
        ),
      ),
    );
  }
}

class _SpeedChip extends StatelessWidget {
  final double speed;
  final Color ink;
  final VoidCallback onTap;
  const _SpeedChip({
    super.key,
    required this.speed,
    required this.ink,
    required this.onTap,
  });

  static String text(double speed) =>
      speed == speed.roundToDouble() ? '${speed.round()}x' : '${speed}x';

  @override
  Widget build(BuildContext context) => PressScale(
    onTap: onTap,
    semanticLabel: 'Playback speed ${text(speed)}. Tap to change',
    borderRadius: BorderRadius.circular(16),
    pressedScale: .94,
    child: SizedBox(
      width: ChatMetrics.hit,
      height: ChatMetrics.hit,
      child: Center(
        child: clampedChrome(
          context,
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ink.withValues(alpha: .6)),
            ),
            child: Text(
              text(speed),
              style: TextStyle(
                color: ink,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The bars of a voice message. [fraction] (0 to 1) is how far it has played; the played bars are drawn solid.
/// With [onSeek] a tap or a drag moves through the message.
class _Waveform extends StatelessWidget {
  final Uint8List wave;
  final double fraction;
  final Color ink;
  final void Function(double fraction)? onSeek;
  const _Waveform({
    super.key,
    required this.wave,
    required this.fraction,
    required this.ink,
    this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final rtl = Directionality.of(context) == TextDirection.rtl;
        void seek(Offset local) {
          if (onSeek == null || box.maxWidth <= 0) return;
          final f = (local.dx / box.maxWidth).clamp(0.0, 1.0);
          onSeek!(rtl ? 1 - f : f);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: onSeek == null ? null : (d) => seek(d.localPosition),
          onHorizontalDragUpdate: onSeek == null
              ? null
              : (d) => seek(d.localPosition),
          child: SizedBox(
            height: 36,
            child: CustomPaint(
              painter: WaveformPainter(
                wave: wave,
                fraction: fraction,
                played: ink,
                rest: ink.withValues(alpha: .38),
                rtl: rtl,
              ),
              size: Size(box.maxWidth, 36),
            ),
          ),
        );
      },
    );
  }
}

/// Draws up to 64 amplitude bytes as rounded bars, vertically centred. Public for the previews.
class WaveformPainter extends CustomPainter {
  final Uint8List wave;
  final double fraction;
  final Color played, rest;
  final bool rtl;
  const WaveformPainter({
    required this.wave,
    required this.fraction,
    required this.played,
    required this.rest,
    this.rtl = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (wave.isEmpty || size.width <= 0) return;
    const gap = 2.0;
    final bars = math.min(wave.length, math.max(1, (size.width / 5).floor()));
    final barWidth = (size.width - gap * (bars - 1)) / bars;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars; i++) {
      // Bars are picked evenly from the bytes when there is not room for all of them.
      final byte = wave[(i * wave.length / bars).floor()];
      final h = math.max(4.0, size.height * (byte / 255) * .9);
      final x = (rtl ? bars - 1 - i : i) * (barWidth + gap);
      final isPlayed = (i + .5) / bars <= fraction;
      paint.color = isPlayed ? played : rest;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - h) / 2, barWidth, h),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.fraction != fraction ||
      old.wave != wave ||
      old.played != played ||
      old.rtl != rtl;
}

// ---------------------------------------------------- recording controls

/// What the composer needs to record: the capture state and what to do with its results.
class VoiceControls {
  final VoiceCapture capture;

  /// Called with the finished clip's sending. The screen sends it.
  final Future<void> Function() onFinish;

  /// A failure to say out loud (permission refused, too short, no file).
  final void Function(String message) onProblem;
  const VoiceControls({
    required this.capture,
    required this.onFinish,
    required this.onProblem,
  });
}

/// The microphone button. Tap it to start a recording that goes on by itself (then send or cancel with the
/// buttons that replace the composer), or hold it: the recording goes while the finger is down, letting go
/// sends it, sliding left (or right in right-to-left languages) cancels it and sliding up locks it so the
/// finger can lift. Screen reader users have the tap and the buttons.
class MicButton extends StatefulWidget {
  final VoiceControls controls;
  const MicButton({super.key, required this.controls});

  /// How far a slide must travel to cancel or to lock.
  static const cancelDistance = 90.0, lockDistance = 70.0;

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton> {
  bool _holding = false, _settled = false;

  VoiceCapture get capture => widget.controls.capture;

  Future<void> _begin({required bool locked}) async {
    final result = await capture.begin(locked: locked);
    switch (result) {
      case CaptureStart.started:
        break;
      case CaptureStart.denied:
        widget.controls.onProblem(
          'Hiyall needs the microphone to record. Allow it in your device settings.',
        );
      case CaptureStart.failed:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Semantics(
      button: true,
      label: 'Record a voice message',
      hint: 'Tap to start recording. Tap send when you are done.',
      excludeSemantics: true,
      onTap: () => unawaited(_begin(locked: true)),
      child: GestureDetector(
        key: const Key('chat-mic'),
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_begin(locked: true)),
        onLongPressStart: (_) {
          _holding = true;
          _settled = false;
          unawaited(_begin(locked: false));
        },
        onLongPressMoveUpdate: (d) {
          if (!_holding || _settled || !capture.recording) return;
          final dx = rtl ? d.offsetFromOrigin.dx : -d.offsetFromOrigin.dx;
          if (dx > MicButton.cancelDistance) {
            _settled = true;
            unawaited(capture.cancel());
          } else if (-d.offsetFromOrigin.dy > MicButton.lockDistance) {
            _settled = true;
            capture.lock();
          }
        },
        onLongPressEnd: (_) {
          final wasHolding = _holding && !_settled;
          _holding = false;
          if (wasHolding) unawaited(widget.controls.onFinish());
        },
        onLongPressCancel: () {
          if (_holding && !_settled) unawaited(capture.cancel());
          _holding = false;
        },
        child: SizedBox(
          width: ChatMetrics.hit,
          height: ChatMetrics.hit,
          child: Center(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: t.surface,
              ),
              child: Icon(Icons.mic_none_rounded, size: 22, color: t.text),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bar that replaces the text field while recording: the bin, a red dot with the time, the live level and,
/// while the finger is down, "Slide to cancel". Locked (tapped or slid up), the send button shows beside it.
class RecordingBar extends StatelessWidget {
  final VoiceCapture capture;
  final VoidCallback onSend;
  const RecordingBar({super.key, required this.capture, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final motion = VibeMotion.duration(context);
    return ListenableBuilder(
      listenable: capture,
      builder: (context, _) {
        final left = Duration(milliseconds: maxVoiceMs - capture.elapsedMs);
        final nearEnd = left <= const Duration(seconds: 30);
        return Semantics(
          container: true,
          liveRegion: false,
          label: 'Recording, ${clockOf(capture.elapsedMs)}',
          child: Row(
            key: const Key('recording-bar'),
            children: [
              ChatIconButton(
                key: const Key('record-cancel'),
                icon: Icons.delete_outline_rounded,
                tooltip: 'Cancel recording',
                onTap: () => unawaited(capture.cancel()),
                color: t.error,
              ),
              _RecordingDot(motion: motion),
              const SizedBox(width: 8),
              clampedChrome(
                context,
                Text(
                  nearEnd
                      ? '${clockOf(capture.elapsedMs)} · ${left.inSeconds}s left'
                      : clockOf(capture.elapsedMs),
                  key: const Key('record-time'),
                  style: TextStyle(
                    color: nearEnd ? t.error : t.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: capture.locked
                    ? LiveBars(levels: capture.levels, color: t.accent)
                    : Text(
                        'Slide to cancel',
                        key: const Key('record-hint'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.textSecondary, fontSize: 14),
                      ),
              ),
              if (capture.locked)
                Tooltip(
                  message: 'Send voice message',
                  child: PressScale(
                    key: const Key('record-send'),
                    onTap: onSend,
                    semanticLabel: 'Send voice message',
                    pressedScale: .88,
                    borderRadius: BorderRadius.circular(24),
                    child: SizedBox(
                      width: ChatMetrics.hit,
                      height: ChatMetrics.hit,
                      child: Center(
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: t.lime,
                          ),
                          child: Icon(
                            Icons.arrow_upward_rounded,
                            size: 22,
                            color: t.onLime,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RecordingDot extends StatefulWidget {
  final Duration motion;
  const _RecordingDot({required this.motion});
  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<_RecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
      _c.value = 1;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Opacity(
        opacity: .45 + .55 * _c.value,
        child: Container(
          key: const Key('record-dot'),
          width: 10,
          height: 10,
          decoration: BoxDecoration(shape: BoxShape.circle, color: t.error),
        ),
      ),
    );
  }
}

/// The newest loudness readings as a row of bars that scrolls as the recording goes on.
class LiveBars extends StatelessWidget {
  final List<double> levels;
  final Color color;
  const LiveBars({super.key, required this.levels, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 32,
    child: CustomPaint(
      painter: _LivePainter(List<double>.of(levels), color),
      size: const Size(double.infinity, 32),
    ),
  );
}

class _LivePainter extends CustomPainter {
  final List<double> levels;
  final Color color;
  _LivePainter(this.levels, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    const bars = VoiceCapture.liveBars;
    final barWidth = math.max(2.0, size.width / bars - 2);
    final paint = Paint()..color = color;
    final start = bars - levels.length;
    for (var i = 0; i < levels.length; i++) {
      final h = math.max(3.0, size.height * levels[i].clamp(0.0, 1.0));
      final x = (start + i) * (size.width / bars);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - h) / 2, barWidth, h),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LivePainter old) => true;
}
