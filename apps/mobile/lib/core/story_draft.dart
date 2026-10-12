import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../shared/story_canvas.dart';

/// The hours a story can be set to stay up. The server decides what a member may use (an
/// unlisted number is refused with a validation error); these are what the app offers.
const storyLifetimeChoices = [6, 12, 24];

/// A story in progress: everything but the photo, which cannot outlive the screen.
class StoryDraft {
  final String text, background, textStyle, align;

  /// Null until the member picks one; then the privacy setting's default applies.
  final String? audience;
  final int lifetimeHours;
  const StoryDraft({
    this.text = '',
    this.background = 'lime',
    this.textStyle = 'clean',
    this.align = 'center',
    this.audience,
    this.lifetimeHours = 24,
  });

  /// Worth keeping: there are words in it.
  bool get hasContent => text.trim().isNotEmpty;

  String encode() => jsonEncode({
    'text': text,
    'background': background,
    'textStyle': textStyle,
    'align': align,
    'audience': audience,
    'lifetimeHours': lifetimeHours,
  });

  /// Reads a saved draft, and null when it is not one. Values this app no longer knows fall back to
  /// the defaults, so a draft saved by another version never breaks the composer.
  static StoryDraft? decode(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final audience = j['audience'];
      final hours = j['lifetimeHours'];
      return StoryDraft(
        text: j['text'] is String ? j['text'] as String : '',
        background: storyBackgrounds.any((b) => b.name == j['background'])
            ? j['background'] as String
            : 'lime',
        textStyle: storyTextStyles.any((s) => s.name == j['textStyle'])
            ? j['textStyle'] as String
            : 'clean',
        align: const ['left', 'center', 'right'].contains(j['align'])
            ? j['align'] as String
            : 'center',
        audience: const ['public', 'followers', 'friends'].contains(audience)
            ? audience as String
            : null,
        lifetimeHours: storyLifetimeChoices.contains(hours) ? hours as int : 24,
      );
    } catch (_) {
      return null;
    }
  }

  static TextAlign alignOf(String name) => switch (name) {
    'left' => TextAlign.left,
    'right' => TextAlign.right,
    _ => TextAlign.center,
  };

  static String nameOf(TextAlign align) => switch (align) {
    TextAlign.left || TextAlign.start => 'left',
    TextAlign.right || TextAlign.end => 'right',
    _ => 'center',
  };
}

/// Where one account's draft is kept on this device.
abstract class StoryDraftStore {
  Future<StoryDraft?> read(String userId);
  Future<void> write(String userId, StoryDraft draft);
  Future<void> clear(String userId);
}

/// Kept in the platform keystore with the other small per-device state. A draft is private words,
/// so it is keyed by account and never leaves the device. Where there is no platform storage
/// (tests, some desktops) nothing is kept and nothing fails.
class SecureStoryDraftStore implements StoryDraftStore {
  const SecureStoryDraftStore();
  static const _storage = FlutterSecureStorage();
  static String _key(String userId) => 'story_draft_$userId';

  @override
  Future<StoryDraft?> read(String userId) async {
    try {
      return StoryDraft.decode(await _storage.read(key: _key(userId)));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String userId, StoryDraft draft) async {
    try {
      await _storage.write(key: _key(userId), value: draft.encode());
    } catch (_) {}
  }

  @override
  Future<void> clear(String userId) async {
    try {
      await _storage.delete(key: _key(userId));
    } catch (_) {}
  }
}

/// A draft store that lives only in memory.
class MemoryStoryDraftStore implements StoryDraftStore {
  final drafts = <String, String>{};
  @override
  Future<StoryDraft?> read(String userId) async =>
      StoryDraft.decode(drafts[userId]);
  @override
  Future<void> write(String userId, StoryDraft draft) async =>
      drafts[userId] = draft.encode();
  @override
  Future<void> clear(String userId) async => drafts.remove(userId);
}

final storyDraftStoreProvider = Provider<StoryDraftStore>(
  (ref) => const SecureStoryDraftStore(),
);
