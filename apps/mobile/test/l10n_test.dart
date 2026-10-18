import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/help_safety.dart';
import 'package:hiyall/l10n/l10n.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

/// Help & Safety shows a pinned-notice and support dot, which read the server: a signed-in fake one.
final _overrides = [
  apiProvider.overrideWithValue(FakeApi()),
  sessionProvider.overrideWith(SignedIn.new),
];

void main() {
  testWidgets('Help & Safety reads its words from the localization scope', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: HelpSafetyScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Help & Safety'), findsOneWidget);
    expect(find.text('CONTACT US'), findsOneWidget);
  });

  testWidgets('a screen under a bare MaterialApp falls back to English', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides,
        child: const MaterialApp(home: Scaffold(body: HelpSafetyScreen())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Help & Safety'), findsOneWidget);
  });

  test('the English template names every string it generates', () {
    final arb = jsonDecode(
      File('lib/l10n/app_en.arb').readAsStringSync(),
    ) as Map<String, dynamic>;
    final keys = [
      for (final k in arb.keys)
        if (!k.startsWith('@')) k,
    ];
    expect(keys, isNotEmpty);
    // Every string carries a description or is plain enough not to need one,
    // and every placeholder is declared.
    for (final k in keys) {
      final text = arb[k] as String;
      final holes = RegExp(r'\{(\w+)\}').allMatches(text).map((m) => m[1]);
      if (holes.isNotEmpty) {
        final meta = arb['@$k'] as Map<String, dynamic>?;
        expect(meta?['placeholders'], isNotNull, reason: '$k has {holes}');
      }
    }
    expect(AppLocalizations.supportedLocales, [const Locale('en')]);
  });
}
