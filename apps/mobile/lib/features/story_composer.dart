import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../core/api.dart';
import '../core/feed_state.dart';
import '../core/picked_file.dart';
import '../core/state.dart';
import '../core/story_draft.dart';
import '../shared/widgets.dart';
import 'pulse.dart';
import 'story_composer/story_actions.dart';
import 'story_composer/story_canvas_stage.dart';
import 'story_composer/story_dialogs.dart';
import 'story_composer/story_dock.dart';
import 'story_composer/story_draft_keeper.dart';
import 'story_composer/story_tap.dart';
import 'story_composer/story_text_input.dart';
import 'story_composer/story_tool_panel.dart';
import 'story_composer/story_tool_tabs.dart';
import 'story_composer/story_top_bar.dart';

export 'story_composer/story_text_input.dart' show storyMaxChars;

/// Making a story: type on a canvas, or put words over a photo.
class StoryComposerScreen extends ConsumerStatefulWidget {
  final ImagePicker? picker;
  const StoryComposerScreen({super.key, this.picker});
  @override
  ConsumerState<StoryComposerScreen> createState() =>
      _StoryComposerScreenState();
}

class _StoryComposerScreenState extends ConsumerState<StoryComposerScreen> {
  final text = StoryTextController();
  final focus = FocusNode();
  late final StoryDraftKeeper _draftKeeper = StoryDraftKeeper(
    ref.read(storyDraftStoreProvider),
    ref.read(sessionProvider).asData?.value?.userId,
  );
  PendingPhoto? photo;
  String background = 'lime', textStyle = 'clean';
  TextAlign align = TextAlign.center;
  int hours = 24;
  String? audience;
  StoryTool tool = StoryTool.colour;
  bool sharing = false, shared = false;

  /// Set by the first change, so a draft that loads late never overwrites what was just typed.
  bool _touched = false;
  Timer? _noteTimer;

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
    if (_draftKeeper.pending) {
      _draftKeeper.cancel();
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
    final draft = await _draftKeeper.read();
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
    _draftKeeper.schedule(_flush);
  }

  void _flush() {
    if (shared) return;
    _draftKeeper.save(_draft);
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
    final choice = await showStoryDiscardDialog(
      context,
      keepable: text.text.trim().isNotEmpty,
    );
    if (!mounted) return;
    if (choice == 'discard') {
      _draftKeeper.cancel();
      _draftKeeper.clear();
      if (mounted) {
        shared = true; // nothing left to protect: lets the pop through
        _leave();
      }
    } else if (choice == 'save') {
      _draftKeeper.cancel();
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
    final p = PendingPhoto(await readAndDeletePick(file));
    unawaited(sweepPickerTemp());
    if (!mounted) return;
    setState(() {
      photo = p;
      if (tool == StoryTool.colour) tool = StoryTool.text;
    });
    await _send(p);
  }

  Future<void> _send(PendingPhoto p) => uploadPendingPhoto(ref, p, 'story', () {
    if (mounted) setState(() {});
  }, onLimit: (m) => mounted ? _say(m) : null);

  void _retryUpload() {
    final p = photo;
    if (p == null) return;
    p.error = null;
    setState(() {});
    unawaited(_send(p));
  }

  Future<void> _chooseSource() async {
    final source = await showStoryPhotoSourceSheet(context);
    if (source != null) await pick(source);
  }

  // ---- Share ------------------------------------------------------------------------------

  bool get ready =>
      !sharing && (photo == null ? text.text.trim().isNotEmpty : photo!.done);

  Future<void> share(String chosen) async {
    if (!ready) return;
    storyBuzz(HapticFeedback.lightImpact);
    setState(() => sharing = true);
    try {
      await ref
          .read(storyActionsProvider)
          .createStory(
            body: text.text.trim(),
            background: background,
            textStyle: textStyle,
            lifetimeHours: hours,
            mediaId: photo?.mediaId,
            audience: chosen,
          );
      shared = true;
      _draftKeeper.cancel();
      // Not awaited: sharing is done, and a slow keystore must not hold the screen.
      _draftKeeper.clear();
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
    storyBuzz(HapticFeedback.selectionClick);
    final next = '$current$added';
    _set(() {
      text.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    });
  }

  void _openTool(StoryTool next) {
    focus.unfocus();
    setState(() => tool = next);
  }

  // ---- Pieces -----------------------------------------------------------------------------

  Widget _canvas() => StoryCanvasStage(
    text: text,
    focus: focus,
    background: background,
    textStyle: textStyle,
    align: align,
    photo: photo,
    note: _note,
    onTap: _focusText,
    onChanged: () => _set(() {}),
    onRetry: _retryUpload,
  );

  Widget _topBar(String chosen) => StoryTopBar(
    count: _count,
    ready: ready,
    sharing: sharing,
    onClose: _close,
    onShare: () => share(chosen),
  );

  Widget _dock(bool typing, String chosen) {
    final tools = [
      if (photo == null) StoryTool.colour,
      StoryTool.text,
      StoryTool.vibes,
      StoryTool.time,
      StoryTool.who,
    ];
    if (!tools.contains(tool)) tool = StoryTool.text;
    return StoryDock(
      typing: typing,
      hasPhoto: photo != null,
      tools: tools,
      tool: tool,
      hours: hours,
      audience: chosen,
      onGallery: () => pick(ImageSource.gallery),
      onCamera: () => pick(ImageSource.camera),
      onChange: _chooseSource,
      onRemove: () => setState(() {
        photo = null;
        _touched = true;
      }),
      onOpenTool: _openTool,
      panel: StoryToolPanel(
        tool: tool,
        background: background,
        textStyle: textStyle,
        audience: chosen,
        align: align,
        hours: hours,
        onBackground: (name) => _set(() => background = name),
        onStyle: (name) => _set(() => textStyle = name),
        onAudience: (key) => _set(() => audience = key),
        onAlign: (a) => _set(() => align = a),
        onHours: (h) => _set(() => hours = h),
        onVibe: _addVibe,
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
                  if (box.maxHeight < 460) {
                    // A short window (a phone on its side): scroll instead of squeezing.
                    return SingleChildScrollView(
                      child: Column(
                        children: [
                          _topBar(chosen),
                          SizedBox(
                            height: 380,
                            child: StoryStageArea(fixed: 380, child: _canvas()),
                          ),
                          _dock(typing, chosen),
                        ],
                      ),
                    );
                  }
                  return Column(
                    children: [
                      _topBar(chosen),
                      Expanded(
                        child: StoryStageArea(fixed: null, child: _canvas()),
                      ),
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
