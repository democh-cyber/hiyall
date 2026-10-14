import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/chat_peers.dart';
import '../core/say_hi_prefs.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/chat_tokens.dart';
import '../shared/widgets.dart' show showMessage;
import 'chat_parts.dart' show clampedChrome;
import 'discover_person.dart';
import 'discover_style.dart';
import 'say_hi.dart';

/// What one row's control and note follow: the board's slice for that person, plus whether a
/// conversation with messages exists with them. Selecting just this keeps every other row still.
SayHiView watchSayHiView(WidgetRef ref, String userId) {
  final conversation = ref.watch(
    chatPeersProvider.select((peers) => peers?.containsKey(userId) ?? false),
  );
  final now = ref.read(sayHiClockProvider)();
  return ref.watch(
    sayHiControllerProvider.select(
      (board) => board.viewOf(userId, now, conversation: conversation),
    ),
  );
}

/// The Say hi control of one row. It rebuilds on its own when its state changes; the screen's list and
/// the row around it stay as they are.
class SayHiSlot extends ConsumerWidget {
  final Profile person;
  final VoidCallback onTap;
  const SayHiSlot({super.key, required this.person, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = watchSayHiView(ref, person.userId);
    return SayHiButton(
      key: Key('say-hi-${person.userId}'),
      name: person.displayName,
      state: view.state,
      onTap: onTap,
    );
  }
}

/// What a tap on a Say hi control does, the same on a Discover row and on a
/// profile. A tap sends a 👋 right there, without leaving the page, through the
/// chat engine as the profile's Message button and the composer do (see
/// [SayHiController]); the very first one asks once. Where a conversation with
/// messages already exists the control is Message and opens it instead. Without
/// chat (the web) it calls [openProfile] (Discover opens the profile, where the
/// Message notice explains) or does nothing when there is none.
Future<void> sayHiTap(
  BuildContext context,
  WidgetRef ref,
  Profile person, {
  Future<void> Function()? openProfile,
}) async {
  final hi = ref.read(sayHiControllerProvider.notifier);
  if (hi.prompting) return;
  if (!ref.read(sayHiAvailableProvider)) {
    await openProfile?.call();
    return;
  }
  final conversation = ref.read(chatPeersProvider)?[person.userId];
  if (conversation != null) {
    context.go(
      '/chats/$conversation?peer=${Uri.encodeQueryComponent(person.userId)}&name=${Uri.encodeQueryComponent(person.displayName)}',
    );
    return;
  }
  hi.prompting = true;
  try {
    if (!await hi.confirmed()) {
      if (!context.mounted) return;
      final yes = await showSendHiSheet(context, person.displayName);
      if (yes != true || !context.mounted) return;
      await hi.confirm();
    }
    await hi.send(person);
  } finally {
    hi.prompting = false;
  }
}

/// The wave on another member's profile, beside Follow and Message: the same
/// control, states and behaviour as a Discover row ([SayHiSlot], [sayHiTap]).
/// Not shown on one's own profile, nor where chat is unavailable (the web: the
/// Message button explains there).
class SayHiProfileButton extends ConsumerWidget {
  final Profile person;
  const SayHiProfileButton({super.key, required this.person});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(
      sessionProvider.select((s) => s.asData?.value?.userId),
    );
    if (me == null || me == person.userId) return const SizedBox.shrink();
    if (!ref.watch(sayHiAvailableProvider)) return const SizedBox.shrink();
    return SayHiSlot(
      person: person,
      onTap: () => sayHiTap(context, ref, person),
    );
  }
}

/// Owns the two timers every screen with a Say hi control needs, so none
/// outlives the screen: the toast's two seconds and a rate limit's rest. With
/// [announce] the toast is also shown as a snackbar (a profile has no list to
/// carry it).
class SayHiEffects extends ConsumerStatefulWidget {
  final Widget child;
  final bool announce;
  const SayHiEffects({super.key, required this.child, this.announce = false});
  @override
  ConsumerState<SayHiEffects> createState() => _SayHiEffectsState();
}

class _SayHiEffectsState extends ConsumerState<SayHiEffects> {
  Timer? _toastTimer, _restTimer;

  @override
  void dispose() {
    _toastTimer?.cancel();
    _restTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sayHiControllerProvider.select((b) => b.toast), (_, toast) {
      _toastTimer?.cancel();
      if (toast == null) return;
      if (widget.announce) showMessage(context, toast.text);
      _toastTimer = Timer(sayHiToastFor, () {
        if (mounted) {
          ref.read(sayHiControllerProvider.notifier).dismissToast(toast.serial);
        }
      });
    });
    ref.listen(sayHiControllerProvider.select((b) => b.rest), (_, rest) {
      _restTimer?.cancel();
      if (rest == null) return;
      _restTimer = Timer(rest.wait, () {
        if (!mounted) return;
        ref.read(sayHiControllerProvider.notifier).endRest(rest.id);
      });
    });
    return widget.child;
  }
}

/// The line under a row when its control has something to say: that encryption is being set up, that
/// the person does not take messages, a rest after a rate limit, or a failure the control can retry.
/// Spoken when it appears.
class SayHiNote extends ConsumerWidget {
  final String userId;
  const SayHiNote({super.key, required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = watchSayHiView(ref, userId).note;
    final s = DiscoverStyle.of(context);
    return AnimatedSize(
      duration: VibeMotion.duration(context),
      alignment: AlignmentDirectional.topStart,
      child: note == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Semantics(
                liveRegion: true,
                child: Row(
                  key: Key('say-hi-note-$userId'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        switch (note.kind) {
                          HiNoteKind.settingUp => Icons.lock_outline_rounded,
                          HiNoteKind.rested => Icons.schedule_rounded,
                          _ => Icons.info_outline_rounded,
                        },
                        size: 15,
                        color: s.noteInk,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        note.text,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.3,
                          color: s.noteInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// The short "👋 sent to Mira" at the bottom of the list. A new one replaces the old at once, it goes
/// by itself after two seconds, and it is announced as a live region. It takes no taps.
class SayHiToastHost extends ConsumerWidget {
  const SayHiToastHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toast = ref.watch(sayHiControllerProvider.select((b) => b.toast));
    final s = DiscoverStyle.of(context);
    final duration = VibeMotion.duration(context);
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: duration,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, .25),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        // A new toast takes the place of the last one rather than stacking above it.
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.bottomCenter,
          children: [...previous, ?current],
        ),
        child: toast == null
            ? const SizedBox.shrink(key: ValueKey(0))
            : KeyedSubtree(
                key: ValueKey(toast.serial),
                child: clampedChrome(
                  context,
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      key: const Key('say-hi-toast'),
                      constraints: const BoxConstraints(maxWidth: 360),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: s.toastFill,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: s.t.hairline),
                        boxShadow: [
                          BoxShadow(
                            color: s.t.shadow,
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Text(
                        toast.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14.5,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          color: s.toastInk,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// The one-time sheet before the member's first wave: it cannot be unsent, so
/// they say yes once ("Send hi") and later waves go out on a tap. True when they
/// chose Send hi, null or false when they dismissed it.
Future<bool?> showSendHiSheet(BuildContext context, String name) =>
    showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final t = ChatTokens.of(context);
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              key: const Key('say-hi-sheet'),
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      'Send a 👋 to $name?',
                      style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontSize: 20,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.3,
                        color: t.text,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'They’ll get it as a message. You can’t unsend it.',
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.4,
                      color: t.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const Key('say-hi-send'),
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Send hi'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      key: const Key('say-hi-cancel'),
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
