import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart' hide PulseApi;
import 'package:hiyall/core/feed_state.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/pulse.dart';

import 'pulse_test.dart' show PulseApi, me, niko;
import 'widget_test.dart' show SignedIn;

/// Pulse screens drawn right-to-left: what sits at the start of a row must
/// land on the right, what sits at the end on the left.
Future<void> pumpRtl(WidgetTester tester, Widget home) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(PulseApi()),
        sessionProvider.overrideWith(SignedIn.new),
        storyTrayProvider.overrideWith(
          (ref) async => [StoryGroup(niko, const [])],
        ),
        profileProvider.overrideWith((ref) => Completer<Profile>().future),
        privacyProvider.overrideWith((ref) => Completer<Privacy>().future),
      ],
      child: MaterialApp(
        builder: (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: home,
      ),
    ),
  );
  await tester.pump();
}

double dx(WidgetTester tester, String key) =>
    tester.getCenter(find.byKey(Key(key))).dx;

void main() {
  const half = 390 / 2;

  testWidgets(
    'A post card mirrors: options on the left, reaction on the right',
    (tester) async {
      final post = Post(
        postId: 'p1',
        author: niko,
        body: 'hello',
        audience: 'public',
        createdAt: DateTime.now(),
      );
      await pumpRtl(
        tester,
        Scaffold(
          body: ListView(children: [PostCard(post: post)]),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(dx(tester, 'post-menu-p1'), lessThan(half));
      expect(dx(tester, 'react-p1'), greaterThan(half));
      expect(dx(tester, 'save-p1'), lessThan(half));
    },
  );

  testWidgets('The story tray starts on the right', (tester) async {
    await pumpRtl(tester, const Scaffold(body: StoryTray()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(dx(tester, 'story-mine'), greaterThan(half));
    expect(
      dx(tester, 'story-${niko.userId}'),
      lessThan(dx(tester, 'story-mine')),
    );
  });

  testWidgets(
    'The composer puts Share on the left and Add photos on the right',
    (tester) async {
      await pumpRtl(tester, const ComposePostScreen());
      expect(tester.takeException(), isNull);
      expect(dx(tester, 'share-post'), lessThan(half));
      expect(dx(tester, 'add-photos'), greaterThan(half));
    },
  );

  testWidgets('The comments sheet puts Send on the left', (tester) async {
    final post = Post(
      postId: 'p1',
      author: me,
      body: 'hello',
      audience: 'public',
      createdAt: DateTime.now(),
      mine: true,
    );
    await pumpRtl(
      tester,
      Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            key: const Key('open'),
            onPressed: () => showComments(context, ref, post, 'following'),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(dx(tester, 'comment-send'), lessThan(half));
    expect(dx(tester, 'comment-input'), greaterThan(half - 1));
  });
}
