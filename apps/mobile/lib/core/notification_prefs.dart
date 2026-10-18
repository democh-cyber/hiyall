import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'state.dart';

/// The member's push choices (`GET` and `PATCH /v1/me/notifications`). The server enforces every one
/// of them when it decides to push; the app only shows the switches. The legacy `social` umbrella is
/// never read or written here.
enum NotificationPref {
  /// Master switch: off silences everything but security alerts.
  enabled('enabled'),
  chat('chat'),
  follows('follows'),
  friendRequests('friendRequests'),
  comments('comments'),
  replies('replies'),
  reactions('reactions'),

  /// Opt-in: a notice when someone opens the profile for the first time.
  visits('visits'),

  /// Social pushes never name the person.
  hideNames('hideNames');

  /// The field name in the API.
  final String field;
  const NotificationPref(this.field);
}

class NotificationPrefs {
  final Map<NotificationPref, bool> _values;
  const NotificationPrefs._(this._values);

  /// What a member without a row has, and what stands in for a field an older server leaves out.
  /// `hideNames` is on for a minor only: the server says so in its answer, never this default.
  static const _defaults = <NotificationPref, bool>{
    NotificationPref.enabled: true,
    NotificationPref.chat: true,
    NotificationPref.follows: true,
    NotificationPref.friendRequests: true,
    NotificationPref.comments: true,
    NotificationPref.replies: true,
    NotificationPref.reactions: true,
    NotificationPref.visits: false,
    NotificationPref.hideNames: false,
  };

  factory NotificationPrefs.fromJson(Map<String, dynamic> json) =>
      NotificationPrefs._({
        for (final p in NotificationPref.values)
          p: json[p.field] as bool? ?? _defaults[p]!,
      });

  bool operator [](NotificationPref p) => _values[p] ?? _defaults[p]!;

  NotificationPrefs withPref(NotificationPref p, bool value) =>
      NotificationPrefs._({..._values, p: value});

  bool get enabled => this[NotificationPref.enabled];
}

/// The choices as the server has them. Each switch sends only its own field, shows the new value at
/// once and goes back to the old one when the server refuses.
final notificationPrefsControllerProvider =
    AsyncNotifierProvider<NotificationPrefsController, NotificationPrefs>(
      NotificationPrefsController.new,
      retry: apiReadRetry,
    );

class NotificationPrefsController extends AsyncNotifier<NotificationPrefs> {
  ApiClient get _api => ref.read(apiProvider);

  /// Changes sent and not answered yet, so a slower answer for one field never undoes a newer tap
  /// on it, and never touches another.
  final _pending = <NotificationPref, int>{};

  @override
  Future<NotificationPrefs> build() async {
    final session = requireSession(ref);
    return NotificationPrefs.fromJson(
      await _api.send(session, 'GET', '/v1/me/notifications')
          as Map<String, dynamic>,
    );
  }

  /// A fresh read after an error ("Try again").
  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
  }

  bool isSaving(NotificationPref p) => (_pending[p] ?? 0) > 0;

  /// Sets one choice. Throws the server's refusal after rolling the switch back; the caller shows it.
  Future<void> set(NotificationPref p, bool value) async {
    final current = state.asData?.value;
    if (current == null) return;
    final before = current[p];
    if (before == value) return;
    final session = requireSession(ref);
    _pending[p] = (_pending[p] ?? 0) + 1;
    state = AsyncData(current.withPref(p, value));
    try {
      final answer = await _api.send(
        session,
        'PATCH',
        '/v1/me/notifications',
        body: {p.field: value},
      ) as Map<String, dynamic>;
      _settle(p);
      if (!ref.mounted) return;
      // Take the server's word for the fields nobody is changing now (it derives some, such as
      // `hideNames` for a minor), and keep this one's: it is what was just confirmed.
      final server = NotificationPrefs.fromJson(answer);
      _update((latest) {
        var next = latest;
        for (final f in NotificationPref.values) {
          if (!isSaving(f)) next = next.withPref(f, server[f]);
        }
        return next;
      });
    } catch (_) {
      _settle(p);
      if (ref.mounted && !isSaving(p)) {
        _update((latest) => latest.withPref(p, before));
      }
      rethrow;
    }
  }

  void _settle(NotificationPref p) {
    final left = (_pending[p] ?? 1) - 1;
    if (left <= 0) {
      _pending.remove(p);
    } else {
      _pending[p] = left;
    }
  }

  void _update(NotificationPrefs Function(NotificationPrefs) change) {
    final latest = state.asData?.value;
    if (latest != null) state = AsyncData(change(latest));
  }
}
