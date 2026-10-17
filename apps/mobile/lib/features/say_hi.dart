import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/chat/chat_api.dart';
import '../core/chat/chat_engine.dart' show ChatEngine;
import '../core/chat_peers.dart';
import '../core/say_hi_prefs.dart';
import '../core/state.dart';
import 'chat.dart' show chatEngineProvider, chatError, chatSupported;
import 'chat_parts.dart' show sendHaptic;
import 'discover_person.dart' show SayHiState;

/// Whether Say hi can send a wave here: end-to-end encrypted chat runs only on
/// Android and iOS. Elsewhere (the web) the button opens the profile, where the
/// Message notice explains. Replaced in tests.
final sayHiAvailableProvider = Provider<bool>((ref) => chatSupported);

/// What a Say hi is: exactly the wave, which the conversation shows as the large
/// emoji-only message.
const sayHiText = '👋';

/// How long the "sent" toast stays up.
const sayHiToastFor = Duration(seconds: 2);

/// The two calls Say hi makes on the chat engine, the same ones the Message
/// button on a profile and the conversation's composer make. Replaced in tests.
abstract interface class HiChat {
  /// Opens (or reopens) the conversation with a person and returns its id.
  Future<String> open(String peerId);

  /// Sends one text message through the engine's normal path (it encrypts for
  /// every device, claims keys and hands the ciphertext to the relay).
  Future<void> send(String conversationId, String peerId, String text);
}

/// Reaching the engine: [ready] says whether it is already up, and [connect] waits for it, which the
/// first time on a device includes creating its keys.
class HiChatLink {
  final bool Function() ready;
  final Future<HiChat> Function() connect;
  const HiChatLink({required this.ready, required this.connect});
}

final hiChatLinkProvider = Provider<HiChatLink>(
  (ref) => HiChatLink(
    ready: () => ref.read(chatEngineProvider).hasValue,
    connect: () async {
      // A failed set-up is tried again, as the Chats screen's retry does.
      if (ref.read(chatEngineProvider).hasError) {
        ref.invalidate(chatEngineProvider);
      }
      final engine = await ref.read(chatEngineProvider.future);
      if (engine == null) {
        throw const ChatFailure(
          'UNSUPPORTED',
          'Chats are available in the Android and iOS apps.',
        );
      }
      return _EngineChat(engine);
    },
  ),
);

class _EngineChat implements HiChat {
  final ChatEngine _engine;
  const _EngineChat(this._engine);
  @override
  Future<String> open(String peerId) => _engine.open(peerId);
  @override
  Future<void> send(String conversationId, String peerId, String text) =>
      _engine.send(conversationId, peerId, text);
}

/// The words for a failed Say hi. A rate limit (429) shows the server's own
/// message, which says when to try again; the wait it asked for (Retry-After)
/// is added when the message does not already say so, and a daily limit that
/// says "Try again later." says how long instead ([ApiFailure.displayMessage]).
String sayHiFailureText(Object error, {String? peerName}) {
  if (error is ChatFailure && error.status == 429) {
    final shown = ApiFailure(
      error.message,
      429,
      error.code,
      error.retryAfter,
    ).displayMessage;
    final wait = error.retryAfter;
    if (wait != null && !shown.toLowerCase().contains('try again')) {
      final seconds = wait.inSeconds;
      return '$shown Try again in ${seconds <= 1
          ? 'a moment'
          : seconds < 90
          ? 'about $seconds seconds'
          : 'a few minutes'}.';
    }
    return shown;
  }
  return chatError(error, peerName: peerName);
}

/// The wait a rate limit asked for, if any, capped at a minute so the control
/// never stays disabled for long.
Duration? sayHiRetryAfter(Object error) {
  if (error is! ChatFailure || error.status != 429) return null;
  final wait = error.retryAfter ?? const Duration(seconds: 10);
  return wait > const Duration(minutes: 1) ? const Duration(minutes: 1) : wait;
}

/// What a row says under itself, beside its control.
enum HiNoteKind { settingUp, notAllowed, unavailable, rested, failed }

class HiNote {
  final HiNoteKind kind;
  final String text;
  const HiNote(this.kind, this.text);
  @override
  bool operator ==(Object other) =>
      other is HiNote && other.kind == kind && other.text == text;
  @override
  int get hashCode => Object.hash(kind, text);
}

/// A refusal turned into the note to show and, for a rate limit, how long to rest.
(HiNote, Duration?) sayHiFault(Object error, String name) {
  if (error is ChatFailure) {
    if (error.code == 'MESSAGES_NOT_ALLOWED') {
      return (
        HiNote(
          HiNoteKind.notAllowed,
          '$name isn’t accepting messages from you.',
        ),
        null,
      );
    }
    if (error.status == 429) {
      return (
        HiNote(HiNoteKind.rested, sayHiFailureText(error)),
        sayHiRetryAfter(error),
      );
    }
    if (error.code == 'CONVERSATION_CLOSED' || error.code == 'NOT_FOUND') {
      return (
        HiNote(HiNoteKind.unavailable, 'You can’t message $name right now.'),
        null,
      );
    }
  }
  final text = error is ApiFailure
      ? error.displayMessage
      : chatError(error, peerName: name);
  return (HiNote(HiNoteKind.failed, text), null);
}

/// The short confirmation at the bottom of the list; [serial] tells a new one from the one it replaced.
class HiToast {
  final String text;
  final int serial;
  const HiToast(this.text, this.serial);
}

/// A rest after a rate limit: for how long, and [id] to tell it from a later one.
class HiRest {
  final int id;
  final Duration wait;
  const HiRest(this.id, this.wait);
}

/// What one row's control looks like and says.
typedef SayHiView = ({SayHiState state, HiNote? note});

/// Everything Say hi remembers while Discover is open: who is being sent to, who was, what each row
/// says and the toast. Rows read only their own slice of it ([viewOf]).
class SayHiBoard {
  /// The person a wave is on its way to; only one at a time.
  final String? sending;

  /// The engine is still being set up for that send (first use on this device).
  final bool settingUp;

  /// When each person was last sent a wave (persisted per account).
  final Map<String, DateTime> sent;

  /// Notes per person; a "not accepting messages" one stays for the session.
  final Map<String, HiNote> notes;

  /// A rate limit asked for a rest: no control sends until the screen ends it ([SayHiController.endRest]).
  final HiRest? rest;
  final HiToast? toast;
  const SayHiBoard({
    this.sending,
    this.settingUp = false,
    this.sent = const {},
    this.notes = const {},
    this.rest,
    this.toast,
  });

  bool get resting => rest != null;

  SayHiBoard copyWith({
    Object? sending = _keep,
    bool? settingUp,
    Map<String, DateTime>? sent,
    Map<String, HiNote>? notes,
    Object? rest = _keep,
    Object? toast = _keep,
  }) => SayHiBoard(
    sending: identical(sending, _keep) ? this.sending : sending as String?,
    settingUp: settingUp ?? this.settingUp,
    sent: sent ?? this.sent,
    notes: notes ?? this.notes,
    rest: identical(rest, _keep) ? this.rest : rest as HiRest?,
    toast: identical(toast, _keep) ? this.toast : toast as HiToast?,
  );

  static const _keep = Object();

  bool sentRecently(String peer, DateTime now) {
    final at = sent[peer];
    return at != null && now.difference(at) < sayHiSentFor;
  }

  /// The state of one person's control at [now], given whether a conversation with messages exists.
  SayHiView viewOf(String peer, DateTime now, {required bool conversation}) {
    final note = notes[peer];
    if (sending == peer) {
      return (
        state: SayHiState.pending,
        note: settingUp
            ? const HiNote(HiNoteKind.settingUp, 'Setting up encryption…')
            : null,
      );
    }
    if (sentRecently(peer, now)) return (state: SayHiState.done, note: null);
    if (conversation) return (state: SayHiState.message, note: null);
    if (note?.kind == HiNoteKind.notAllowed ||
        note?.kind == HiNoteKind.unavailable) {
      return (state: SayHiState.notAllowed, note: note);
    }
    if (note?.kind == HiNoteKind.failed && !resting && sending == null) {
      return (state: SayHiState.retry, note: note);
    }
    if (resting || sending != null) {
      return (state: SayHiState.disabled, note: note);
    }
    return (state: SayHiState.idle, note: note);
  }
}

final sayHiControllerProvider = NotifierProvider<SayHiController, SayHiBoard>(
  SayHiController.new,
);

/// Sends the wave and keeps the board. One tap sends exactly one 👋: opening the
/// conversation and sending the text go through the chat engine as the profile's
/// Message button and the composer do, and nothing here navigates.
class SayHiController extends Notifier<SayHiBoard> {
  String? _userId;

  /// Set from a tap until it has been handed on (the first-time sheet included), so a double tap
  /// cannot start two, wherever the control is (a row, a profile).
  bool prompting = false;
  var _serial = 0;

  @override
  SayHiBoard build() {
    final userId = ref.watch(
      sessionProvider.select((s) => s.asData?.value?.userId),
    );
    _userId = userId;
    if (userId != null) unawaited(_load(userId));
    return const SayHiBoard();
  }

  bool _live(String userId) => ref.mounted && _userId == userId;

  Future<void> _load(String userId) async {
    final loaded = freshSent(
      await ref.read(sayHiPrefsStoreProvider).sent(userId),
      ref.read(sayHiClockProvider)(),
    );
    if (_live(userId)) state = state.copyWith(sent: {...loaded, ...state.sent});
  }

  /// Whether the member already confirmed the first-time "Send a 👋?" sheet.
  Future<bool> confirmed() async {
    final userId = _userId;
    return userId != null &&
        await ref.read(sayHiPrefsStoreProvider).confirmed(userId);
  }

  Future<void> confirm() async {
    final userId = _userId;
    if (userId == null) return;
    await ref.read(sayHiPrefsStoreProvider).markConfirmed(userId);
  }

  void _note(String peer, HiNote? note) {
    final notes = {...state.notes};
    note == null ? notes.remove(peer) : notes[peer] = note;
    state = state.copyWith(notes: notes);
  }

  /// Rests every control for [wait] after a rate limit. The screen owns the timer and calls
  /// [endRest] (see `PeopleDiscovery`), so none outlives it.
  void _restFor(Duration wait) =>
      state = state.copyWith(rest: HiRest(++_serial, wait));

  void endRest(int id) {
    if (state.rest?.id != id) return;
    state = state.copyWith(rest: null, notes: _withoutRested());
  }

  Map<String, HiNote> _withoutRested() => {
    for (final e in state.notes.entries)
      if (e.value.kind != HiNoteKind.rested) e.key: e.value,
  };

  void _showToast(String text) =>
      state = state.copyWith(toast: HiToast(text, ++_serial));

  /// The toast's two seconds are over (the screen's timer).
  void dismissToast(int serial) {
    if (state.toast?.serial == serial) state = state.copyWith(toast: null);
  }

  /// Back on Discover: a toast or a rest left over from before the screen was left is over.
  void reset() {
    if (state.toast == null && state.rest == null) return;
    state = state.copyWith(toast: null, rest: null, notes: _withoutRested());
  }

  /// Sends a 👋 to [person]. A second call while one is on its way, during a rest, or for someone
  /// already waved at (or who refuses messages) does nothing.
  Future<void> send(Profile person) async {
    final userId = _userId;
    final peer = person.userId;
    if (userId == null || state.sending != null || state.resting) return;
    final now = ref.read(sayHiClockProvider)();
    final kind = state.notes[peer]?.kind;
    if (state.sentRecently(peer, now) ||
        kind == HiNoteKind.notAllowed ||
        kind == HiNoteKind.unavailable) {
      return;
    }
    final link = ref.read(hiChatLinkProvider);
    final notes = {...state.notes}..remove(peer);
    state = state.copyWith(
      sending: peer,
      settingUp: !link.ready(),
      notes: notes,
    );
    try {
      final chat = await link.connect();
      if (!_live(userId)) return;
      if (state.settingUp) state = state.copyWith(settingUp: false);
      final id = await chat.open(peer);
      await chat.send(id, peer, sayHiText);
      if (!_live(userId)) return;
      final sent = {
        ...freshSent(state.sent, ref.read(sayHiClockProvider)()),
        peer: ref.read(sayHiClockProvider)(),
      };
      state = state.copyWith(sending: null, settingUp: false, sent: sent);
      unawaited(ref.read(sayHiPrefsStoreProvider).saveSent(userId, sent));
      ref.read(chatPeersProvider.notifier).add(peer, id);
      _showToast('$sayHiText sent to ${person.displayName}');
      unawaited(sendHaptic());
    } catch (e) {
      if (!_live(userId)) return;
      final (note, wait) = sayHiFault(e, person.displayName);
      state = state.copyWith(sending: null, settingUp: false);
      _note(peer, note);
      if (wait != null) _restFor(wait);
    }
  }
}
