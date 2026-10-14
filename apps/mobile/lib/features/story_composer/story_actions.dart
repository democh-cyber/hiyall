import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  }) => _ref
      .read(apiProvider)
      .createStory(
        _ref.read(sessionProvider).asData!.value!,
        body: body,
        background: background,
        textStyle: textStyle,
        lifetimeHours: lifetimeHours,
        mediaId: mediaId,
        audience: audience,
      );
}

final storyActionsProvider = Provider<StoryActions>(StoryActions.new);
