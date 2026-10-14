import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../shared/story_canvas.dart';
import '../pulse.dart' show PendingPhoto;
import 'story_text_input.dart';

/// Fits a 9:16 canvas into whatever room there is, keeping a small margin and a minimum size.
class StoryStageArea extends StatelessWidget {
  /// A fixed height to fit into, for the scrolling layout; otherwise the room offered.
  final double? fixed;
  final Widget child;
  const StoryStageArea({super.key, required this.fixed, required this.child});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, area) {
      final h = (fixed ?? area.maxHeight) - 8;
      final w = math.min(area.maxWidth - 32, h * 9 / 16);
      return Center(
        child: SizedBox(
          width: math.max(w, 80),
          height: math.max(w, 80) * 16 / 9,
          child: child,
        ),
      );
    },
  );
}

/// The story itself: the canvas with its text field, the photo upload state and the short
/// note over it. A snack bar would cover the controls the note is about.
class StoryCanvasStage extends StatelessWidget {
  final StoryTextController text;
  final FocusNode focus;
  final String background, textStyle;
  final TextAlign align;
  final PendingPhoto? photo;
  final String? note;
  final VoidCallback onTap;
  final VoidCallback onChanged;
  final VoidCallback onRetry;
  const StoryCanvasStage({
    super.key,
    required this.text,
    required this.focus,
    required this.background,
    required this.textStyle,
    required this.align,
    required this.photo,
    required this.note,
    required this.onTap,
    required this.onChanged,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = photo;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1f000000),
              blurRadius: 18,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(27),
          child: Stack(
            fit: StackFit.expand,
            children: [
              StoryCanvas(
                key: const Key('story-canvas'),
                animate: true,
                background: background,
                textStyle: textStyle,
                body: text.text,
                align: align,
                photo: p == null
                    ? null
                    : Image.memory(
                        p.bytes,
                        fit: BoxFit.cover,
                        cacheWidth: 1080,
                      ),
                editor: (context, look) => _StoryTextEditor(
                  look: look,
                  text: text,
                  focus: focus,
                  onChanged: onChanged,
                ),
              ),
              if (p != null && !p.done)
                _StoryUploadOverlay(photo: p, onRetry: onRetry),
              if (note != null) _StoryNote(message: note!),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoryNote extends StatelessWidget {
  final String message;
  const _StoryNote({required this.message});
  @override
  Widget build(BuildContext context) => PositionedDirectional(
    top: 14,
    start: 14,
    end: 14,
    child: IgnorePointer(
      child: Center(
        child: Semantics(
          liveRegion: true,
          child: Container(
            key: const Key('story-note'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xe6101210),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _StoryTextEditor extends StatelessWidget {
  final StoryTextLook look;
  final StoryTextController text;
  final FocusNode focus;
  final VoidCallback onChanged;
  const _StoryTextEditor({
    required this.look,
    required this.text,
    required this.focus,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    text.spec = look.spec;
    final hint = look.style.copyWith(
      color: look.hint,
      backgroundColor: Colors.transparent,
      shadows: const [],
    );
    return SizedBox(
      width: double.infinity,
      child: MediaQuery(
        // Story text is art sized by the layout, not by the reader's text size.
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
        child: Semantics(
          label: 'Story text',
          textField: true,
          child: TextField(
            key: const Key('story-text'),
            controller: text,
            focusNode: focus,
            maxLines: null,
            textAlign: look.align,
            textCapitalization: TextCapitalization.sentences,
            keyboardType: TextInputType.multiline,
            inputFormatters: const [StoryRuneLimit(storyMaxChars)],
            style: look.style,
            cursorColor: look.ink,
            cursorWidth: math.max(2, 3 * look.scale),
            // Tapping a tool must not close the keyboard.
            onTapOutside: (_) {},
            onChanged: (_) => onChanged(),
            // The theme's filled, outlined fields are for forms; here the words sit on the canvas.
            decoration: InputDecoration(
              isCollapsed: true,
              filled: false,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              hintText: 'Type your vibe…',
              hintStyle: hint,
            ),
          ),
        ),
      ),
    );
  }
}

class _StoryUploadOverlay extends StatelessWidget {
  final PendingPhoto photo;
  final VoidCallback onRetry;
  const _StoryUploadOverlay({required this.photo, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final p = photo;
    final failed = p.error != null;
    final body = ColoredBox(
      color: Colors.black45,
      child: Center(
        child: failed
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  p.limited
                      ? '${p.error!}\nRemove it to post words instead.'
                      : '${p.error!}\nTap to try again.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            : CircularProgressIndicator(
                value: p.progress > 0 ? p.progress : null,
                color: Colors.white,
              ),
      ),
    );
    if (!failed || p.limited) return Positioned.fill(child: body);
    return Positioned.fill(
      child: Semantics(
        button: true,
        label: 'Try uploading the photo again',
        excludeSemantics: true,
        child: GestureDetector(
          key: const Key('story-retry'),
          onTap: onRetry,
          child: body,
        ),
      ),
    );
  }
}
