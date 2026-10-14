import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/story_draft.dart';
import 'package:hiyall/features/story_composer/story_actions.dart';
import 'package:hiyall/features/story_composer/story_draft_keeper.dart';

import 'pulse_test.dart' as pt;
import 'widget_test.dart' show SignedIn;

class SignedOut extends SessionController {
  @override
  AsyncValue<Session?> build() => const AsyncData(null);
}

ProviderContainer container(pt.PulseApi api, [bool signedIn = true]) {
  final c = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(signedIn ? SignedIn.new : SignedOut.new),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('StoryActions', () {
    test(
      'createStory sends every field through the api in the provider',
      () async {
        final api = pt.PulseApi();
        await container(api)
            .read(storyActionsProvider)
            .createStory(
              body: 'gm',
              background: 'pink',
              textStyle: 'bold',
              lifetimeHours: 12,
              mediaId: 'm1',
              audience: 'friends',
            );
        expect(api.storySent, {
          'body': 'gm',
          'background': 'pink',
          'textStyle': 'bold',
          'lifetimeHours': 12,
          'mediaId': 'm1',
          'audience': 'friends',
        });
      },
    );

    test('a failure from the server reaches the caller', () {
      final api = pt.PulseApi()..storyFailure = const ApiFailure('No.', 400);
      expect(
        container(api)
            .read(storyActionsProvider)
            .createStory(
              body: 'gm',
              background: 'lime',
              textStyle: 'clean',
              lifetimeHours: 24,
              mediaId: null,
              audience: 'public',
            ),
        throwsA(isA<ApiFailure>()),
      );
    });
  });

  group('StoryDraftKeeper', () {
    final draft = StoryDraft(
      text: 'hello',
      background: 'lime',
      textStyle: 'clean',
      align: 'center',
      audience: null,
      lifetimeHours: 24,
    );

    test('saves a draft with content, clears one without', () async {
      final store = MemoryStoryDraftStore();
      final keeper = StoryDraftKeeper(store, 'u1');
      keeper.save(draft);
      await Future<void>.delayed(Duration.zero);
      expect((await keeper.read())?.text, 'hello');
      keeper.save(
        StoryDraft(
          text: '',
          background: 'lime',
          textStyle: 'clean',
          align: 'center',
          audience: null,
          lifetimeHours: 24,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(await keeper.read(), isNull);
    });

    test('without a user it reads and writes nothing', () async {
      final store = MemoryStoryDraftStore();
      final keeper = StoryDraftKeeper(store, null);
      keeper.save(draft);
      keeper.clear();
      expect(await keeper.read(), isNull);
      expect(store.drafts, isEmpty);
    });

    test('schedule runs once after a moment and cancel stops it', () async {
      final keeper = StoryDraftKeeper(MemoryStoryDraftStore(), 'u1');
      var runs = 0;
      keeper.schedule(() => runs++);
      keeper.schedule(() => runs++);
      expect(keeper.pending, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(runs, 1);
      expect(keeper.pending, isFalse);
      keeper.schedule(() => runs++);
      keeper.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(runs, 1);
    });
  });
}
