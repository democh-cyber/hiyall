import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/shared/profile_space.dart';

// RTL smoke for the profile space: no overflow, and start-aligned content
// (section titles, the about rows) sits on the right.
Future<void> host(WidgetTester tester, TextDirection direction) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  const profile = Profile(
    userId: 'id',
    username: 'rtl_user',
    displayName: 'Rtl User',
    bio: 'Short bio',
    profession: 'Maker',
    version: '',
    interests: ['Music', 'Hiking'],
    currentVibe: 'Calm',
  );
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          Directionality(textDirection: direction, child: child!),
      home: Scaffold(
        body: ProfileSpace(
          profile: profile,
          isOwner: true,
          onEdit: () {},
          onSettings: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Profile space mirrors in RTL without overflow', (tester) async {
    await host(tester, TextDirection.ltr);
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(find.text('MY INTERESTS')).dx, lessThan(100));
    expect(
      tester.getCenter(find.byTooltip('Your space settings')).dx,
      greaterThan(195),
    );
    expect(tester.getCenter(find.text('Rtl User')).dx, closeTo(195, 1));

    await host(tester, TextDirection.rtl);
    expect(tester.takeException(), isNull);
    expect(tester.getTopRight(find.text('MY INTERESTS')).dx, greaterThan(290));
    expect(
      tester.getCenter(find.byTooltip('Your space settings')).dx,
      lessThan(195),
    );
    expect(tester.getCenter(find.text('Rtl User')).dx, closeTo(195, 1));
  });
}
