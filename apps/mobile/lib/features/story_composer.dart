import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../core/api.dart';
import '../core/feed_state.dart';
import '../core/state.dart';
import '../core/story_draft.dart';
import '../core/theme.dart';
import '../shared/story_canvas.dart';
import '../shared/widgets.dart';
import 'pulse.dart';

/// The server's limit on a story's words, counted in characters (code points), not UTF-16 units.
const storyMaxChars = 280;

const _vibes = [
  ('😴', 'sleepy'),
  ('🔥', 'on fire'),
  ('🎧', 'vibing'),
  ('🌧️', 'gloomy'),
  ('📍', 'out and about'),
  ('🥳', 'celebrating'),
  ('😎', 'chilling'),
  ('📚', 'studying'),
  ('🍕', 'snack time'),
  ('🎮', 'gaming'),
  ('🥹', 'feeling things'),
  ('✨', 'main character'),
];

const _audienceEmoji = {'public': '🌍', 'followers': '👥', 'friends': '💚'};

const _audienceHints = {
  'public': 'Anyone on Hiyall can watch',
  'followers': 'Only your followers',
  'friends': 'Only your friends',
};

enum _Tool { colour, text, vibes, time, who }

/// Keeps at most [max] characters (code points), the way the server counts them.
class _RuneLimit extends TextInputFormatter {
  final int max;
  const _RuneLimit(this.max);
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.runes.length <= max) return newValue;
    final cut = String.fromCharCodes(newValue.text.runes.take(max));
    return TextEditingValue(
      text: cut,
      selection: TextSelection.collapsed(offset: cut.length),
    );
  }
}

/// Shows upper-case styles in capitals without changing what was typed.
class _StoryTextController extends TextEditingController {
  StoryTextSpec spec = storyTextStyles.first;
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final shown = storyDisplayText(text, spec);
    if (shown == text) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return TextSpan(style: style, text: shown);
  }
}

void _buzz(Future<void> Function() haptic) {
  // Platforms without a motor, and tests, just do nothing.
  unawaited(haptic().catchError((_) {}));
}

/// A tap target with the app's press feel: a small scale, a ring for keyboard focus, no ink.
/// At least 48 × 48 whatever the look inside is.
class _Tap extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool? selected;
  final double scale;
  final double radius;
  final Widget Function(bool pressed) builder;
  const _Tap({
    super.key,
    required this.label,
    required this.onTap,
    required this.builder,
    this.selected,
    this.scale = .94,
    this.radius = 24,
  });
  @override
  State<_Tap> createState() => _TapState();
}

class _TapState extends State<_Tap> {
  bool _pressed = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: AnimatedScale(
                scale: _pressed && !reduce ? widget.scale : 1,
                duration: const Duration(milliseconds: 90),
                child: Container(
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.radius),
                    border: Border.all(
                      color: _focused ? scheme.onSurface : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: widget.builder(_pressed),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pill: lime when [on], a quiet surface otherwise.
BoxDecoration _pill(
  BuildContext context, {
  bool on = false,
  double radius = 24,
}) {
  final scheme = Theme.of(context).colorScheme;
  return BoxDecoration(
    color: on ? VibeColors.lime : scheme.surfaceContainerHigh,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: on ? VibeColors.lime : scheme.outlineVariant,
      width: 1.5,
    ),
  );
}

TextStyle _pillText(BuildContext context, {bool on = false, double? size}) =>
    TextStyle(
      fontFamily: 'Manrope',
      fontWeight: on ? FontWeight.w800 : FontWeight.w700,
      fontSize: size ?? 14,
      color: on ? VibeColors.ink : Theme.of(context).colorScheme.onSurface,
    );

/// Making a story: type on a canvas, or put words over a photo.
class StoryComposerScreen extends ConsumerStatefulWidget {
  final ImagePicker? picker;
  const StoryComposerScreen({super.key, this.picker});
  @override
  ConsumerState<StoryComposerScreen> createState() =>
      _StoryComposerScreenState();
}

class _StoryComposerScreenState extends ConsumerState<StoryComposerScreen> {
  final text = _StoryTextController();
  final focus = FocusNode();
  late final StoryDraftStore _drafts = ref.read(storyDraftStoreProvider);
  late final String? _userId = ref.read(sessionProvider).asData?.value?.userId;
  PendingPhoto? photo;
  String background = 'lime', textStyle = 'clean';
  TextAlign align = TextAlign.center;
  int hours = 24;
  String? audience;
  _Tool tool = _Tool.colour;
  bool sharing = false, shared = false;

  /// Set by the first change, so a draft that loads late never overwrites what was just typed.
  bool _touched = false;
  Timer? _save, _noteTimer;

  /// A short message over the canvas. A snack bar would cover the controls it is about.
  String? _note;

  ImagePicker get picker => widget.picker ?? ImagePicker();

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  @override
  void dispose() {
    // A change still waiting for its save is written now: closing the screen never loses it.
    if (_save?.isActive ?? false) {
      _save!.cancel();
      _flush();
    }
    _noteTimer?.cancel();
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  void _say(String message) {
    _noteTimer?.cancel();
    setState(() => _note = message);
    _noteTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _note = null);
    });
  }

  // ---- Draft ------------------------------------------------------------------------------

  StoryDraft get _draft => StoryDraft(
    text: text.text,
    background: background,
    textStyle: textStyle,
    align: StoryDraft.nameOf(align),
    audience: audience,
    lifetimeHours: hours,
  );

  Future<void> _restore() async {
    final id = _userId;
    if (id == null) return;
    final draft = await _drafts.read(id);
    if (!mounted || _touched || draft == null || !draft.hasContent) return;
    setState(() {
      text.value = TextEditingValue(
        text: draft.text,
        selection: TextSelection.collapsed(offset: draft.text.length),
      );
      background = draft.background;
      textStyle = draft.textStyle;
      align = StoryDraft.alignOf(draft.align);
      audience = draft.audience;
      hours = draft.lifetimeHours;
    });
    _say('Picked up where you left off.');
  }

  /// Every change saves the draft a moment later; typing does not write on every key.
  void _changed() {
    _touched = true;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 250), _flush);
  }

  void _flush() {
    final id = _userId;
    if (id == null || shared) return;
    unawaited(
      _draft.hasContent ? _drafts.write(id, _draft) : _drafts.clear(id),
    );
  }

  // ---- Leaving ----------------------------------------------------------------------------

  bool get _hasUnsent =>
      !shared && (text.text.trim().isNotEmpty || photo != null);

  void _leave() {
    final router = GoRouter.maybeOf(context);
    if (router == null) {
      Navigator.of(context).pop();
    } else if (router.canPop()) {
      router.pop();
    } else {
      router.go('/home');
    }
  }

  Future<void> _close() async {
    if (!_hasUnsent) {
      _leave();
      return;
    }
    final keepable = text.text.trim().isNotEmpty;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Discard draft?'),
        content: Text(
          keepable
              ? 'This story isn’t shared yet. Save it for later or throw it away.'
              : 'This story isn’t shared yet. Your photo will be thrown away.',
        ),
        actions: [
          TextButton(
            key: const Key('keep-editing'),
            onPressed: () => Navigator.pop(dialog, 'keep'),
            child: const Text('Keep editing'),
          ),
          if (keepable)
            TextButton(
              key: const Key('save-draft'),
              onPressed: () => Navigator.pop(dialog, 'save'),
              child: const Text('Save draft'),
            ),
          FilledButton(
            key: const Key('discard-draft'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.pop(dialog, 'discard'),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'discard') {
      _save?.cancel();
      final id = _userId;
      if (id != null) unawaited(_drafts.clear(id));
      if (mounted) {
        shared = true; // nothing left to protect: lets the pop through
        _leave();
      }
    } else if (choice == 'save') {
      _save?.cancel();
      _flush();
      if (mounted) {
        shared = true;
        _leave();
      }
    }
  }

  // ---- Photo ------------------------------------------------------------------------------

  Future<void> pick(ImageSource source) async {
    final XFile? file;
    try {
      file = await picker.pickImage(
        source: source,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
    } catch (_) {
      if (mounted) {
        _say('Couldn’t open that. Check Hiyall’s photo access.');
      }
      return;
    }
    if (file == null) return;
    final p = PendingPhoto(await file.readAsBytes());
    if (!mounted) return;
    setState(() {
      photo = p;
      if (tool == _Tool.colour) tool = _Tool.text;
    });
    await _send(p);
  }

  Future<void> _send(PendingPhoto p) => uploadPendingPhoto(ref, p, 'story', () {
    if (mounted) setState(() {});
  }, onLimit: (m) => mounted ? _say(m) : null);

  Future<void> _chooseSource() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Photo library'),
              onTap: () => Navigator.pop(sheet, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(sheet, ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source != null) await pick(source);
  }

  // ---- Share ------------------------------------------------------------------------------

  bool get ready =>
      !sharing && (photo == null ? text.text.trim().isNotEmpty : photo!.done);

  Future<void> share(String chosen) async {
    if (!ready) return;
    _buzz(HapticFeedback.lightImpact);
    setState(() => sharing = true);
    try {
      await ref
          .read(apiProvider)
          .createStory(
            ref.read(sessionProvider).asData!.value!,
            body: text.text.trim(),
            background: background,
            textStyle: textStyle,
            lifetimeHours: hours,
            mediaId: photo?.mediaId,
            audience: chosen,
          );
      shared = true;
      _save?.cancel();
      final id = _userId;
      // Not awaited: sharing is done, and a slow keystore must not hold the screen.
      if (id != null) unawaited(_drafts.clear(id));
      ref.invalidate(storyTrayProvider);
      if (mounted) {
        showMessage(context, 'Added to your story.');
        _leave();
      }
    } catch (e) {
      if (mounted) {
        _say(e is ApiFailure ? e.displayMessage : 'Couldn’t share. Try again.');
      }
    } finally {
      if (mounted) setState(() => sharing = false);
    }
  }

  // ---- Editing ----------------------------------------------------------------------------

  void _set(VoidCallback change) {
    setState(change);
    _changed();
  }

  void _focusText() {
    if (focus.hasFocus) {
      // The keyboard may have been dismissed while the field kept focus.
      unawaited(
        SystemChannels.textInput
            .invokeMethod<void>('TextInput.show')
            .catchError((_) {}),
      );
    } else {
      focus.requestFocus();
    }
  }

  int get _count => text.text.runes.length;

  /// Adds "😴 sleepy" after what is there, if it fits.
  void _addVibe(String emoji, String word) {
    final current = text.text;
    final gap =
        current.isEmpty || current.endsWith(' ') || current.endsWith('\n')
        ? ''
        : ' ';
    final added = '$gap$emoji $word';
    if (_count + added.runes.length > storyMaxChars) {
      _say('Not enough room left for that.');
      return;
    }
    _buzz(HapticFeedback.selectionClick);
    final next = '$current$added';
    _set(() {
      text.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    });
  }

  void _openTool(_Tool next) {
    focus.unfocus();
    setState(() => tool = next);
  }

  // ---- Pieces -----------------------------------------------------------------------------

  Widget _editor(StoryTextLook look) {
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
            inputFormatters: const [_RuneLimit(storyMaxChars)],
            style: look.style,
            cursorColor: look.ink,
            cursorWidth: math.max(2, 3 * look.scale),
            // Tapping a tool must not close the keyboard.
            onTapOutside: (_) {},
            onChanged: (_) => _set(() {}),
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

  Widget _canvas() {
    final scheme = Theme.of(context).colorScheme;
    final p = photo;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _focusText,
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
                editor: (context, look) => _editor(look),
              ),
              if (p != null && !p.done) _uploadOverlay(p),
              if (_note != null)
                Positioned(
                  top: 14,
                  left: 14,
                  right: 14,
                  child: IgnorePointer(
                    child: Center(
                      child: Semantics(
                        liveRegion: true,
                        child: Container(
                          key: const Key('story-note'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xe6101210),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            _note!,
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
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _uploadOverlay(PendingPhoto p) {
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
          onTap: () {
            p.error = null;
            setState(() {});
            unawaited(_send(p));
          },
          child: body,
        ),
      ),
    );
  }

  Widget _topBar(String chosen) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          _Tap(
            key: const Key('story-close'),
            label: 'Close',
            radius: 24,
            onTap: _close,
            builder: (_) => Container(
              width: 48,
              height: 48,
              decoration: _pill(context, radius: 24),
              child: Icon(Icons.close_rounded, color: scheme.onSurface),
            ),
          ),
          const Spacer(),
          _CharRing(count: _count),
          const SizedBox(width: 12),
          _Tap(
            key: const Key('share-story'),
            label: sharing ? 'Sharing your story' : 'Share story',
            radius: 26,
            scale: .9,
            onTap: ready ? () => share(chosen) : null,
            builder: (pressed) => AnimatedContainer(
              key: Key(ready ? 'share-ready' : 'share-idle'),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 22),
              decoration: BoxDecoration(
                gradient: ready
                    ? const LinearGradient(
                        colors: [VibeColors.lime, Color(0xff5eead4)],
                      )
                    : null,
                borderRadius: BorderRadius.circular(26),
                border: ready
                    ? null
                    : Border.all(color: scheme.outlineVariant, width: 1.5),
                boxShadow: ready
                    ? [
                        BoxShadow(
                          color: VibeColors.lime.withValues(
                            alpha: pressed ? .65 : .3,
                          ),
                          blurRadius: pressed ? 22 : 12,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (sharing) ...[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: VibeColors.ink,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    sharing ? 'Sharing…' : 'Share',
                    style: TextStyle(
                      fontFamily: 'SpaceGrotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: ready
                          ? VibeColors.ink
                          : scheme.onSurface.withValues(alpha: .38),
                    ),
                  ),
                  if (!sharing) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.arrow_upward_rounded,
                      size: 18,
                      color: ready
                          ? VibeColors.ink
                          : scheme.onSurface.withValues(alpha: .38),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mediaRow() {
    Widget big(Key key, String label, IconData icon, VoidCallback onTap) =>
        Expanded(
          child: _Tap(
            key: key,
            label: label,
            radius: 20,
            onTap: onTap,
            builder: (_) => Container(
              height: 52,
              alignment: Alignment.center,
              decoration: _pill(context, radius: 20),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: const BoxDecoration(
                        color: VibeColors.lime,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, size: 18, color: VibeColors.ink),
                    ),
                    const SizedBox(width: 10),
                    Text(label, style: _pillText(context, size: 15)),
                  ],
                ),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: photo == null
            ? [
                big(
                  const Key('story-gallery'),
                  'Photo',
                  Icons.photo_library_rounded,
                  () => pick(ImageSource.gallery),
                ),
                const SizedBox(width: 10),
                big(
                  const Key('story-camera'),
                  'Camera',
                  Icons.photo_camera_rounded,
                  () => pick(ImageSource.camera),
                ),
              ]
            : [
                big(
                  const Key('story-change-photo'),
                  'Change photo',
                  Icons.swap_horiz_rounded,
                  _chooseSource,
                ),
                const SizedBox(width: 10),
                big(
                  const Key('story-remove-photo'),
                  'Remove',
                  Icons.close_rounded,
                  () => setState(() {
                    photo = null;
                    _touched = true;
                  }),
                ),
              ],
      ),
    );
  }

  Widget _tabs(List<_Tool> tools, String chosen) {
    (String, String, String) look(_Tool t) => switch (t) {
      _Tool.colour => ('🎨', 'Colour', 'Colour'),
      _Tool.text => ('Aa', 'Text', 'Text style'),
      _Tool.vibes => ('✨', 'Vibes', 'Vibes'),
      _Tool.time => ('⏳', '${hours}h', 'Lasts $hours hours'),
      _Tool.who => (
        _audienceEmoji[chosen]!,
        audienceLabels[chosen]!,
        'Who can see this: ${audienceLabels[chosen]}',
      ),
    };
    return SizedBox(
      height: 48,
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final t in tools)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _Tap(
                    key: Key('tool-${t.name}'),
                    label: look(t).$3,
                    selected: t == tool,
                    onTap: () => _openTool(t),
                    builder: (_) => Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: _pill(context, on: t == tool),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            look(t).$1,
                            style: TextStyle(
                              fontFamily: look(t).$1 == 'Aa'
                                  ? 'SpaceGrotesk'
                                  : null,
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              color: t == tool
                                  ? VibeColors.ink
                                  : Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            look(t).$2,
                            style: _pillText(context, on: t == tool),
                          ),
                        ],
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

  Widget _panel(_Tool t, String chosen) => switch (t) {
    _Tool.colour => _SwatchRow(
      selected: background,
      onPick: (name) {
        _buzz(HapticFeedback.selectionClick);
        _set(() => background = name);
      },
    ),
    _Tool.text => _textPanel(),
    _Tool.vibes => _vibesPanel(),
    _Tool.time => _timePanel(),
    _Tool.who => _whoPanel(chosen),
  };

  Widget _scrollRow(List<Widget> children) => Center(
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: children),
    ),
  );

  Widget _textPanel() {
    Widget alignButton(TextAlign a, IconData icon, String label) => _Tap(
      key: Key('align-${StoryDraft.nameOf(a)}'),
      label: label,
      selected: align == a,
      radius: 24,
      onTap: () {
        _buzz(HapticFeedback.selectionClick);
        _set(() => align = a);
      },
      builder: (_) => Container(
        width: 44,
        height: 44,
        decoration: align == a ? _pill(context, on: true, radius: 22) : null,
        child: Icon(
          icon,
          color: align == a
              ? VibeColors.ink
              : Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
    return _scrollRow([
      alignButton(
        TextAlign.left,
        Icons.format_align_left_rounded,
        'Align left',
      ),
      alignButton(
        TextAlign.center,
        Icons.format_align_center_rounded,
        'Align centre',
      ),
      alignButton(
        TextAlign.right,
        Icons.format_align_right_rounded,
        'Align right',
      ),
      const SizedBox(width: 8),
      for (final spec in storyTextStyles)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: _Tap(
            key: Key('style-${spec.name}'),
            label: '${spec.label} text style',
            selected: textStyle == spec.name,
            onTap: () {
              _buzz(HapticFeedback.selectionClick);
              _set(() => textStyle = spec.name);
            },
            builder: (_) {
              final on = textStyle == spec.name;
              return Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: _pill(context, on: on),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      storyDisplayText('Aa', spec),
                      style: spec.style(
                        ink: on
                            ? VibeColors.ink
                            : Theme.of(context).colorScheme.onSurface,
                        px: 20,
                        k: 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(spec.label, style: _pillText(context, on: on)),
                  ],
                ),
              );
            },
          ),
        ),
    ]);
  }

  Widget _vibesPanel() => _scrollRow([
    for (final (emoji, word) in _vibes)
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: _Tap(
          key: Key('vibe-$word'),
          label: '$emoji $word',
          onTap: () => _addVibe(emoji, word),
          builder: (_) => Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: _pill(context),
            child: Text('$emoji $word', style: _pillText(context)),
          ),
        ),
      ),
  ]);

  Widget _timePanel() => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final h in storyLifetimeChoices)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: _Tap(
                  key: Key('hours-$h'),
                  label: 'Lasts $h hours',
                  selected: hours == h,
                  onTap: () {
                    _buzz(HapticFeedback.selectionClick);
                    _set(() => hours = h);
                  },
                  builder: (_) {
                    final on = hours == h;
                    return Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      alignment: Alignment.center,
                      decoration: _pill(context, on: on),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.schedule_rounded,
                            size: 16,
                            color: on
                                ? VibeColors.ink
                                : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${h}h',
                            style: _pillText(context, on: on, size: 15),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      Text(
        'Gone $hours hours after you share',
        key: const Key('hours-hint'),
        style: TextStyle(
          fontSize: 12.5,
          height: 1.2,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );

  Widget _whoPanel(String chosen) {
    final scheme = Theme.of(context).colorScheme;
    final duration = VibeMotion.duration(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(100),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              children: [
                for (final e in audienceLabels.entries)
                  Expanded(
                    child: _Tap(
                      key: Key('audience-${e.key}'),
                      label: e.value,
                      selected: chosen == e.key,
                      radius: 100,
                      onTap: () {
                        _buzz(HapticFeedback.selectionClick);
                        _set(() => audience = e.key);
                      },
                      builder: (_) => AnimatedContainer(
                        duration: duration,
                        curve: Curves.easeOutCubic,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: chosen == e.key
                              ? VibeColors.lime
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(100),
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '${_audienceEmoji[e.key]} ${e.value}',
                            style: _pillText(context, on: chosen == e.key),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        AnimatedSwitcher(
          duration: duration,
          child: Text(
            _audienceHints[chosen]!,
            key: ValueKey(chosen),
            style: TextStyle(
              fontSize: 12.5,
              height: 1.2,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _dock(bool typing, String chosen) {
    final tools = [
      if (photo == null) _Tool.colour,
      _Tool.text,
      _Tool.vibes,
      _Tool.time,
      _Tool.who,
    ];
    if (!tools.contains(tool)) tool = _Tool.text;
    // With the keyboard up there is only room for the tabs; opening one closes the keyboard.
    // The controls grow with the reader's text size, up to 1.3x, so the canvas keeps its room.
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!typing) _mediaRow(),
          _tabs(tools, chosen),
          if (!typing)
            SizedBox(
              height: 88,
              child: AnimatedSwitcher(
                duration: VibeMotion.duration(context),
                child: KeyedSubtree(
                  key: ValueKey(tool),
                  child: _panel(tool, chosen),
                ),
              ),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final setting =
        ref.watch(privacyProvider).asData?.value.values['storyAudience']
            as String?;
    final chosen = audience ?? defaultAudience(setting);
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: !_hasUnsent,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: LayoutBuilder(
                builder: (context, box) {
                  final compact = box.maxHeight < 460;
                  Widget area(double? fixed) => LayoutBuilder(
                    builder: (context, area) {
                      final h = (fixed ?? area.maxHeight) - 8;
                      final w = math.min(area.maxWidth - 32, h * 9 / 16);
                      return Center(
                        child: SizedBox(
                          width: math.max(w, 80),
                          height: math.max(w, 80) * 16 / 9,
                          child: _canvas(),
                        ),
                      );
                    },
                  );
                  if (compact) {
                    // A short window (a phone on its side): scroll instead of squeezing.
                    return SingleChildScrollView(
                      child: Column(
                        children: [
                          _topBar(chosen),
                          SizedBox(height: 380, child: area(380)),
                          _dock(typing, chosen),
                        ],
                      ),
                    );
                  }
                  return Column(
                    children: [
                      _topBar(chosen),
                      Expanded(child: area(null)),
                      _dock(typing, chosen),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The remaining characters as a ring around the top bar: it fills as the story does, turns
/// amber near the limit and shows how many are left when it gets tight.
class _CharRing extends StatelessWidget {
  final int count;
  const _CharRing({required this.count});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final share = (count / storyMaxChars).clamp(0.0, 1.0);
    final left = storyMaxChars - count;
    final color = share >= 1
        ? scheme.error
        : share >= .85
        ? const Color(0xffffb020)
        : scheme.primary;
    return Semantics(
      label: '$count of $storyMaxChars characters used',
      excludeSemantics: true,
      child: SizedBox(
        key: const Key('story-counter'),
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size.square(34),
              painter: _RingPainter(share, scheme.outlineVariant, color),
            ),
            if (share >= .85)
              Text(
                '$left',
                key: const Key('story-counter-left'),
                style: TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: color,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double value;
  final Color track, fill;
  const _RingPainter(this.value, this.track, this.fill);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      rect.deflate(2),
      0,
      math.pi * 2,
      false,
      paint..color = track,
    );
    if (value > 0) {
      canvas.drawArc(
        rect.deflate(2),
        -math.pi / 2,
        math.pi * 2 * value,
        false,
        paint..color = fill,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.track != track || old.fill != fill;
}

/// A scrolling row of chunky circular swatches. The chosen one grows, gets a ring and settles
/// with a tiny bounce (no bounce when the device asks for less motion).
class _SwatchRow extends StatefulWidget {
  final String selected;
  final ValueChanged<String> onPick;
  const _SwatchRow({required this.selected, required this.onPick});
  @override
  State<_SwatchRow> createState() => _SwatchRowState();
}

class _SwatchRowState extends State<_SwatchRow> {
  static const _slot = 64.0;
  late final controller = ScrollController(
    initialScrollOffset: math.max(
      0,
      storyBackgrounds.indexWhere((b) => b.name == widget.selected) * _slot -
          90,
    ),
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduce = MediaQuery.disableAnimationsOf(context);
    // Every swatch is built, so each one is reachable by screen readers and keyboards.
    Widget swatch(StoryBackground b) {
      final on = b.name == widget.selected;
      return Center(
        child: _Tap(
          key: Key('swatch-${b.name}'),
          label: '${b.name} background',
          selected: on,
          radius: 32,
          scale: .9,
          onTap: () => widget.onPick(b.name),
          builder: (_) => SizedBox(
            width: _slot - 8,
            height: _slot - 8,
            child: Center(
              child: AnimatedScale(
                scale: on ? 1.14 : 1,
                duration: reduce
                    ? Duration.zero
                    : const Duration(milliseconds: 320),
                curve: Curves.easeOutBack,
                child: AnimatedContainer(
                  duration: reduce
                      ? Duration.zero
                      : const Duration(milliseconds: 160),
                  width: 52,
                  height: 52,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: on ? scheme.onSurface : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: b.gradient,
                      border: Border.all(
                        color: scheme.outlineVariant,
                        width: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      key: const Key('swatches'),
      controller: controller,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [for (final b in storyBackgrounds) swatch(b)]),
    );
  }
}
