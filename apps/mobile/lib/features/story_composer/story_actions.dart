import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/pulse7.dart';
import '../../core/state.dart';

/// The server calls the story composer makes. Reads [apiProvider] and the session at call
/// time, so a test's override or a session change is always honoured.
class StoryActions {
  final Ref _ref;
  StoryActions(this._ref);

  Future<void> createStory({
    required String body,
    required String background,
    required String textStyle,
    required int lifetimeHours,
    required String? mediaId,
    required String audience,
    String? topic,
    String? voiceMediaId,
  }) {
    final session = _ref.read(sessionProvider).asData!.value!;
    // A topic or a voice note goes through the newer call; a plain story keeps the first one.
    if (topic != null || voiceMediaId != null) {
      return _ref
          .read(pulse7Provider)
          .createStory(
            session,
            body: body,
            background: background,
            textStyle: textStyle,
            lifetimeHours: lifetimeHours,
            mediaId: mediaId,
            audience: audience,
            topic: topic,
            voiceMediaId: voiceMediaId,
          );
    }
    return _ref
        .read(apiProvider)
        .createStory(
          session,
          body: body,
          background: background,
          textStyle: textStyle,
          lifetimeHours: lifetimeHours,
          mediaId: mediaId,
          audience: audience,
        );
  }
}

final storyActionsProvider = Provider<StoryActions>(StoryActions.new);
