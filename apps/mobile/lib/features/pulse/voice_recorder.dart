import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/pulse7.dart';
import '../../core/theme.dart';
import '../../core/user_error.dart';
import '../../core/voice.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/press_scale.dart';
import 'pulse_actions.dart';
import 'voice_player.dart';

/// Records one voice note of up to 60 seconds, lets the member listen to it, record it again or throw it away,
/// and uploads it when they choose to use it. It hands the uploaded clip to [onAttached]; [onClose] leaves
/// without one. The microphone, the player and the files are behind providers, so tests run without a phone.
class VoiceRecorderPanel extends ConsumerStatefulWidget {
  final ValueChanged<VoiceUpload> onAttached;
  final VoidCallback onClose;

  /// Scroll inside the panel instead of growing (the story composer gives it a fixed height).
  final bool scroll;
  final EdgeInsetsGeometry margin;
  const VoiceRecorderPanel({
    super.key,
    required this.onAttached,
    required this.onClose,
    this.scroll = false,
    this.margin = EdgeInsets.zero,
  });

  @override
  ConsumerState<VoiceRecorderPanel> createState() => _VoiceRecorderPanelState();
}

class _VoiceRecorderPanelState extends ConsumerState<VoiceRecorderPanel> {
  late final NoteCapture capture = NoteCapture(
    recorder: ref.read(noteRecorderProvider),
    newPath: ref.read(notePathProvider),
    files: ref.read(noteFilesProvider),
  );
  late final ClipPlayback playback = ref.read(clipPlaybackProvider);
  bool uploading = false;
  Object? uploadError;

  @override
  void dispose() {
    capture.dispose();
    super.dispose();
  }

  Future<void> record() async {
    // Nothing else may play into the microphone.
    await playback.stop();
    setState(() => uploadError = null);
    await capture.start();
  }

  Future<void> useIt() async {
    final note = capture.note;
    if (note == null || uploading) return;
    await playback.stop();
    setState(() {
      uploading = true;
      uploadError = null;
    });
    try {
      final bytes = await capture.bytes();
      final upload = await ref.read(pulseActionsProvider).uploadVoice(bytes);
      await capture.consumed();
      if (mounted) widget.onAttached(upload);
    } catch (e) {
      if (mounted) setState(() => uploadError = e);
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  Future<void> close() async {
    await capture.cancel();
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return ListenableBuilder(
      listenable: capture,
      builder: (context, _) {
        Widget body = _body(context, t);
        if (widget.scroll) body = SingleChildScrollView(child: body);
        return Container(
          key: const Key('voice-panel'),
          margin: widget.margin,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: t.hairline),
          ),
          child: body,
        );
      },
    );
  }

  Widget _body(BuildContext context, ChatTokens t) {
    if (uploading) {
      return Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Adding your voice note…',
              style: TextStyle(color: t.text),
            ),
          ),
        ],
      );
    }
    final error = uploadError;
    if (error != null) {
      return _Message(
        icon: Icons.error_outline_rounded,
        text: friendlyError(error),
        actions: [
          FilledButton(
            key: const Key('voice-retry'),
            onPressed: useIt,
            child: const Text('Try again'),
          ),
          TextButton(
            key: const Key('voice-rerecord'),
            onPressed: () {
              setState(() => uploadError = null);
              record();
            },
            child: const Text('Record again'),
          ),
        ],
      );
    }
    switch (capture.stage) {
      case NoteStage.idle:
        return Row(
          children: [
            _RoundButton(
              key: const Key('voice-record'),
              label: 'Start recording',
              icon: Icons.mic_rounded,
              fill: VibeColors.lime,
              ink: VibeColors.ink,
              onTap: record,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Tap to record. Up to $maxVoiceSeconds seconds.',
                style: TextStyle(color: t.text, height: 1.3),
              ),
            ),
            _CloseButton(onTap: close),
          ],
        );
      case NoteStage.starting:
        return Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Getting the microphone ready…',
                style: TextStyle(color: t.text),
              ),
            ),
          ],
        );
      case NoteStage.recording:
        final left = capture.remaining;
        return Row(
          children: [
            _RoundButton(
              key: const Key('voice-cancel'),
              label: 'Cancel recording',
              icon: Icons.delete_outline_rounded,
              fill: t.elevated,
              ink: t.text,
              onTap: close,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: 'Recording, ${clipTime(left)} left',
                    excludeSemantics: true,
                    child: Text(
                      '${clipTime(left)} left',
                      key: const Key('voice-countdown'),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: left.inSeconds <= 10 ? t.error : t.text,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  ExcludeSemantics(
                    child: WaveBars(
                      bars: _live(capture.levels),
                      progress: 1,
                      played: t.accent,
                      rest: t.hairline,
                      height: 24,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _RoundButton(
              key: const Key('voice-stop'),
              label: 'Stop recording',
              icon: Icons.stop_rounded,
              fill: VibeColors.lime,
              ink: VibeColors.ink,
              onTap: capture.stop,
            ),
          ],
        );
      case NoteStage.recorded:
        final note = capture.note!;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            VoicePlayerBar(
              id: 'draft',
              source: ClipSource.file(note.path),
              duration: Duration(milliseconds: note.durationMs),
              label: 'Your recording',
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                TextButton.icon(
                  key: const Key('voice-rerecord'),
                  onPressed: record,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Record again'),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      key: const Key('voice-discard'),
                      onPressed: close,
                      child: const Text('Discard'),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      key: const Key('voice-use'),
                      onPressed: useIt,
                      child: const Text('Use this'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
      case NoteStage.denied:
        return _Message(
          icon: Icons.mic_off_rounded,
          title: 'Hiyall can’t use the microphone yet',
          text: 'Allow it in Settings to record a voice note. Nothing is recorded until you tap record.',
          actions: [
            FilledButton(
              key: const Key('voice-open-settings'),
              onPressed: () => ref.read(appSettingsOpenerProvider)(),
              child: const Text('Open settings'),
            ),
            TextButton(
              key: const Key('voice-retry'),
              onPressed: record,
              child: const Text('Try again'),
            ),
            TextButton(
              key: const Key('voice-close'),
              onPressed: close,
              child: const Text('Close'),
            ),
          ],
        );
      case NoteStage.failed:
        return _Message(
          icon: Icons.error_outline_rounded,
          text: capture.problem ?? 'That didn’t work. Try again.',
          actions: [
            FilledButton(
              key: const Key('voice-retry'),
              onPressed: record,
              child: const Text('Try again'),
            ),
            TextButton(
              key: const Key('voice-close'),
              onPressed: close,
              child: const Text('Close'),
            ),
          ],
        );
    }
  }

  /// The live bars: the newest readings, padded with quiet ones at the start so the strip never jumps.
  List<double> _live(List<double> levels) => [
    for (var i = 0; i < NoteCapture.liveBars - levels.length; i++) .08,
    for (final l in levels) l.clamp(.08, 1.0),
  ];
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String? title;
  final String text;
  final List<Widget> actions;
  const _Message({
    required this.icon,
    required this.text,
    required this.actions,
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: t.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    Text(
                      title!,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: t.text,
                      ),
                    ),
                  Text(
                    text,
                    style: TextStyle(color: t.textSecondary, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: actions),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color fill, ink;
  final VoidCallback onTap;
  const _RoundButton({
    super.key,
    required this.label,
    required this.icon,
    required this.fill,
    required this.ink,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => PressScale(
    minHeight: 48,
    semanticLabel: label,
    onTap: onTap,
    child: Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
      child: Icon(icon, color: ink, size: 26),
    ),
  );
}

class _CloseButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CloseButton({required this.onTap});
  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('voice-close'),
    tooltip: 'Close voice note',
    onPressed: onTap,
    icon: const Icon(Icons.close_rounded),
  );
}

/// The voice note part of a composer: a button that opens the recorder, the recorder itself, and once a note is
/// attached its player with a way to remove it.
class VoiceNoteField extends ConsumerStatefulWidget {
  final VoiceUpload? value;
  final ValueChanged<VoiceUpload?> onChanged;

  /// In the story composer's tool panel: the recorder is always open (the tab is the opener), with a fixed
  /// height it scrolls inside.
  final bool compact;
  const VoiceNoteField({
    super.key,
    required this.value,
    required this.onChanged,
    this.compact = false,
  });

  @override
  ConsumerState<VoiceNoteField> createState() => _VoiceNoteFieldState();
}

class _VoiceNoteFieldState extends ConsumerState<VoiceNoteField> {
  bool open = false;

  /// Bumped to start a closed compact recorder over.
  int _generation = 0;

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final value = widget.value;
    final compact = widget.compact;
    if (value != null) {
      return Container(
        key: const Key('voice-attached'),
        margin: compact
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 4)
            : EdgeInsets.zero,
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: t.hairline),
        ),
        child: Row(
          children: [
            Expanded(
              child: VoicePlayerBar(
                id: value.mediaId,
                source: ClipSource.url(value.url),
                duration: Duration(milliseconds: value.durationMs),
                label: 'Your voice note',
              ),
            ),
            IconButton(
              key: const Key('voice-remove'),
              tooltip: 'Remove voice note',
              onPressed: () => widget.onChanged(null),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      );
    }
    if (open || compact) {
      return VoiceRecorderPanel(
        key: ValueKey(_generation),
        scroll: compact,
        margin: compact
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 4)
            : EdgeInsets.zero,
        onAttached: (v) {
          setState(() => open = false);
          widget.onChanged(v);
        },
        onClose: () => setState(() {
          open = false;
          _generation++;
        }),
      );
    }
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: OutlinedButton.icon(
        key: const Key('add-voice'),
        onPressed: () => setState(() => open = true),
        icon: const Icon(Icons.mic_none_rounded),
        label: const Text('Add a voice note'),
      ),
    );
  }
}
