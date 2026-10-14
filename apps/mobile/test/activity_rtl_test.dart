import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/features/activity.dart';

// RTL smoke for the Activity screen: no overflow, and the heading and its
// actions swap sides.
Future<void> host(WidgetTester tester, TextDirection direction) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final items = [
    for (var i = 0; i < 6; i++)
      {
        'notificationId': 'n$i',
        'type': 'like',
        'actors': [
          {'userId': 'u$i', 'username': 'p$i', 'displayName': 'Person $i'},
        ],
        'count': 1,
        'createdAt': DateTime(2026, 10, 7, 11).toUtc().toIso8601String(),
        'text': 'Person $i liked your post.',
      },
  ];
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          Directionality(textDirection: direction, child: child!),
      home: Scaffold(
        body: ActivityView(
          activity: AsyncData(items),
          now: DateTime(2026, 10, 7, 12),
          onSettings: () {},
          onMarkAllRead: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Activity header mirrors in RTL without overflow', (
    tester,
  ) async {
    await host(tester, TextDirection.ltr);
    expect(tester.takeException(), isNull);
    final ltrTitle = tester.getCenter(find.text('Activity')).dx;
    final ltrSettings = tester
        .getCenter(find.byTooltip('Activity visibility'))
        .dx;
    expect(ltrTitle, lessThan(195));
    expect(ltrSettings, greaterThan(195));

    await host(tester, TextDirection.rtl);
    expect(tester.takeException(), isNull);
    expect(tester.getCenter(find.text('Activity')).dx, greaterThan(195));
    expect(
      tester.getCenter(find.byTooltip('Activity visibility')).dx,
      lessThan(195),
    );
  });
}
