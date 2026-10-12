import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/features/chat_photo_states.dart';

/// The overlays are drawn at the photo's size: as small as 198 x 110 on a
/// 320 px phone. They must fit, at any text size, with no overflow.
Future<void> pump(
  WidgetTester tester,
  Widget state, {
  Size photo = const Size(198, 110),
  double scale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: photo.width,
              height: photo.height,
              child: ColoredBox(color: Colors.blueGrey, child: state),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('loading says what it is waiting for and shows progress', (
    tester,
  ) async {
    await pump(tester, const PhotoLoadingState(progress: .4));
    expect(find.text('Loading photo…'), findsOneWidget);
    final ring = tester.widget<CircularProgressIndicator>(
      find.byKey(const Key('photo-loading-ring')),
    );
    expect(ring.value, .4);
    final h = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Loading photo'), findsOneWidget);
    h.dispose();
  });

  testWidgets('loading spins until a first progress arrives', (tester) async {
    await pump(tester, const PhotoLoadingState());
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byKey(const Key('photo-loading-ring')),
          )
          .value,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failure says so and offers a Retry that works', (tester) async {
    var retried = 0;
    await pump(
      tester,
      PhotoRetryState(retryKey: const Key('retry'), onRetry: () => retried++),
    );
    expect(find.text('Couldn’t load photo'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('retry'))).height,
      greaterThanOrEqualTo(44),
    );
    await tester.tap(find.byKey(const Key('retry')));
    expect(retried, 1);
    final h = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Retry loading photo'), findsOneWidget);
    h.dispose();
  });

  testWidgets('expired says Photo expired and why, with nothing to retry', (
    tester,
  ) async {
    await pump(tester, const PhotoExpiredState());
    expect(find.text('Photo expired'), findsOneWidget);
    expect(find.textContaining('30 days'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.byType(GestureDetector), findsNothing);
  });

  testWidgets('damaged says it cannot be opened', (tester) async {
    await pump(tester, const PhotoDamagedState());
    expect(find.text('Can’t open this photo'), findsOneWidget);
  });

  for (final scale in [1.0, 2.0]) {
    for (final photo in [const Size(198, 110), const Size(198, 264)]) {
      testWidgets('every state fits a ${photo.width.toInt()}x'
          '${photo.height.toInt()} photo at text x$scale', (tester) async {
        for (final state in <Widget>[
          const PhotoLoadingState(progress: .5),
          PhotoRetryState(onRetry: () {}),
          const PhotoExpiredState(),
          const PhotoDamagedState(),
        ]) {
          await pump(tester, state, photo: photo, scale: scale);
          expect(tester.takeException(), isNull, reason: '$state');
          final plate = tester.getRect(find.byType(PhotoStatePlate));
          expect(plate.width, lessThanOrEqualTo(photo.width + .5));
          expect(plate.height, lessThanOrEqualTo(photo.height + .5));
        }
      });
    }
  }
}
