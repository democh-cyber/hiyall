import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/profile_editor.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

const profile = Profile(
  userId: 'u1',
  username: 'anjali',
  displayName: 'Anjali',
  bio: 'hello',
  profession: '',
  version: '1',
);

Future<void> open(WidgetTester tester, TextDirection direction) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(FakeApi()),
        sessionProvider.overrideWith(SignedIn.new),
      ],
      child: MaterialApp(
        theme: hiyallTheme(Brightness.light),
        builder: (context, child) =>
            Directionality(textDirection: direction, child: child!),
        home: const Scaffold(body: ProfileForm(profile: profile)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final direction in TextDirection.values) {
    final rtl = direction == TextDirection.rtl;
    testWidgets('profile editor lays out for $direction without overflow', (
      tester,
    ) async {
      await open(tester, direction);
      expect(tester.takeException(), isNull);
      // The camera badge sits on the end side of the photo.
      final avatar = tester.getCenter(find.byKey(const Key('edit-avatar'))).dx;
      final badge = tester
          .getCenter(
            find.descendant(
              of: find.byKey(const Key('edit-avatar')),
              matching: find.byIcon(Icons.photo_camera_rounded),
            ),
          )
          .dx;
      expect(badge > avatar, !rtl);
      // The back button sits at the start edge.
      final back = tester.getCenter(find.text('Profile')).dx;
      expect(back < 195, !rtl);
    });
  }
}
