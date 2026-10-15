import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';

import 'support/fixtures.dart';
import 'support/live_dev_session.dart';

void main() {
  test(
    'Flutter client reads the live API and logout invalidates its token',
    () async {
      final api = ApiClient();
      final session = await liveDevSession(anjaliId);
      try {
        final profile = await api.profile(session);
        final privacy = await api.privacy(session);
        final sessions = await api.sessions(session);
        expect(profile.userId, anjaliId);
        expect(profile.version, isNotEmpty);
        expect(profile.socialStats, isNotNull);
        expect(profile.socialStats!.friends, greaterThanOrEqualTo(0));
        expect(profile.socialStats!.following, greaterThanOrEqualTo(0));
        expect(profile.socialStats!.followers, greaterThanOrEqualTo(0));
        expect(privacy.values['fieldAudiences']['connections'], isNotNull);
        expect(privacy.version, isNotEmpty);
        expect(
          (sessions['items'] as List).any((s) => s['current'] == true),
          isTrue,
        );
      } finally {
        await api.logout(session);
      }
      await expectLater(
        api.profile(session),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 401)),
      );
    },
    skip: !const bool.fromEnvironment('RUN_LIVE_API_TEST'),
  );
}
