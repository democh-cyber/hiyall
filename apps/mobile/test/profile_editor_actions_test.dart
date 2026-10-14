import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/profile_editor/profile_editor_actions.dart';
import 'package:hiyall/features/profile_editor/profile_form_fields.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

class RecordingApi extends FakeApi {
  final sent = <(String, Map<String, dynamic>)>[];
  @override
  Future<Profile> updateProfile(
    Session s,
    Profile p,
    Map<String, dynamic> patch,
  ) async {
    sent.add((s.token, patch));
    return p;
  }
}

class SignedOut extends SessionController {
  @override
  AsyncValue<Session?> build() => const AsyncData(null);
}

const profile = Profile(
  userId: 'u1',
  username: 'anjali',
  displayName: 'Anjali',
  bio: ' hello ',
  profession: '',
  version: '1',
  gender: 'robot',
  profileAccent: 'plaid',
);

ProviderContainer container(ApiClient api, [bool signedIn = true]) {
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
  group('ProfileEditorActions', () {
    test(
      'saveProfile and setAvatar go through the api in the provider',
      () async {
        final api = RecordingApi();
        final actions = container(api).read(profileEditorActionsProvider);
        expect(actions.session?.token, 'test-only-token');
        await actions.saveProfile(profile, {'headline': 'hi'});
        await actions.setAvatar(actions.session!, profile, 'media-1');
        await actions.setAvatar(actions.session!, profile, null);
        expect(api.sent.map((e) => e.$2), [
          {'headline': 'hi'},
          {'avatarMediaId': 'media-1'},
          {'avatarMediaId': null},
        ]);
      },
    );

    test('without a session there is none to read and a save throws', () {
      final actions = container(
        RecordingApi(),
        false,
      ).read(profileEditorActionsProvider);
      expect(actions.session, isNull);
      expect(actions.saveProfile(profile, {}), throwsA(anything));
    });
  });

  group('ProfileFormFields', () {
    test('starts from the profile and falls back on unknown choices', () {
      final fields = ProfileFormFields(profile);
      addTearDown(fields.dispose);
      expect(fields.gender, '');
      expect(fields.accent, 'lime');
      expect(fields.pattern, 'glow');
      expect(fields.frame, 'minimal');
    });

    test('patch trims the text and carries the choices', () {
      final fields = ProfileFormFields(profile);
      addTearDown(fields.dispose);
      fields.name.text = '  Anji ';
      fields.interests.add('Art');
      fields.country = 'IN';
      final patch = fields.patch();
      expect(patch['displayName'], 'Anji');
      expect(patch['bio'], 'hello');
      expect(patch['interests'], ['Art']);
      expect(patch['country'], 'IN');
      expect(patch['profileAccent'], 'lime');
    });
  });
}
