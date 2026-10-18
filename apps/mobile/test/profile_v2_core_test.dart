import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/discover_prefs.dart';
import 'package:hiyall/core/discovery.dart';
import 'package:hiyall/core/local_time.dart';
import 'package:hiyall/core/personality.dart';
import 'package:hiyall/core/profile_labels.dart';
import 'package:hiyall/core/profile_limits.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/shared/profile_space/profile_details.dart'
    show birthdayText;

import 'widget_test.dart' show SignedIn;

Map<String, dynamic> baseProfile([Map<String, dynamic> extra = const {}]) => {
  'userId': 'u1',
  'username': 'mira',
  'displayName': 'Mira',
  ...extra,
};

void main() {
  group('language levels', () {
    test('a level is a number from 1 to 6 and a bare tag reads as 3', () {
      expect(ProfileLanguage.fromJson('en').level, 3);
      expect(ProfileLanguage.fromJson({'code': 'ko', 'level': 5}).level, 5);
      expect(ProfileLanguage.fromJson({'code': 'ko'}).level, 3);
      expect(ProfileLanguage.fromJson({'code': 'ko', 'level': 9}).level, 6);
      expect(ProfileLanguage.fromJson({'code': 'ko', 'level': 0}).level, 1);
    });

    test('the older words map to numbers', () {
      final levels = {
        for (final word in ['basic', 'conversational', 'fluent', 'native'])
          word: ProfileLanguage.fromJson({'code': 'x', 'level': word}).level,
      };
      expect(levels, {
        'basic': 2,
        'conversational': 3,
        'fluent': 4,
        'native': 6,
      });
      expect(
        ProfileLanguage.fromJson({'code': 'x', 'level': 'weird'}).level,
        3,
      );
    });

    test('writes carry a number, never a word', () {
      expect(const ProfileLanguage('en', 4).toJson(), {
        'code': 'en',
        'level': 4,
      });
      expect(const ProfileLanguage('en').withLevel(6).level, 6);
    });

    test('there is a name and a hint for each of the six levels', () {
      expect(languageLevelNames.length, 7);
      expect(languageLevelHints.length, 7);
      expect(
        [for (var i = 1; i <= 6; i++) languageLevelName(i)],
        [
          'Just starting',
          'Beginner',
          'Conversational',
          'Fluent',
          'Advanced',
          'Native',
        ],
      );
      expect(languageLevelName(0), 'Not specified');
      expect(languageLevelName(7), 'Not specified');
    });
  });

  group('personality tags', () {
    test('19 distinct tags with labels and icons', () {
      expect(personalityTags, hasLength(19));
      expect({for (final t in personalityTags) t.id}, hasLength(19));
      expect({for (final t in personalityTags) t.label}, hasLength(19));
      expect(minPersonalityTags, 3);
      expect(maxPersonalityTags, 5);
    });

    test('an id this version does not know is still readable', () {
      expect(personalityTagLabel('night_owl'), 'Night owl');
      expect(personalityTagLabel('future_tag'), 'Future tag');
      expect(personalityTagById('future_tag'), isNull);
    });
  });

  group('profile fields', () {
    test('the v2 fields read, and are empty when the server sent none', () {
      final p = Profile.fromJson(baseProfile());
      expect(p.personalityTags, isEmpty);
      expect(p.aboutMe, '');
      expect(p.hometown, '');
      expect(p.localTime, isNull);
      expect(p.birthday, isNull);
      expect(p.photos, isEmpty);
      expect(p.visitorsVisible, isFalse);
      final full = Profile.fromJson(
        baseProfile({
          'personalityTags': ['curious', 'maker', 'foodie'],
          'aboutMe': 'Slow mornings',
          'hometown': 'Lisbon',
          'localTime': {'utcOffsetMinutes': 330, 'label': 'UTC+5:30'},
          'birthday': {'month': 5, 'day': 17},
          'visitorsVisible': true,
          'photos': [
            {
              'mediaId': 'm1',
              'url': 'https://x/full',
              'thumbUrl': 'https://x/thumb',
              'width': 800,
              'height': 600,
            },
          ],
          'reasons': ['interests', 'languages'],
        }),
      );
      expect(full.personalityTags, ['curious', 'maker', 'foodie']);
      expect(full.aboutMe, 'Slow mornings');
      expect(full.hometown, 'Lisbon');
      expect(full.localTime!.utcOffsetMinutes, 330);
      expect(full.localTime!.label, 'UTC+5:30');
      expect(full.birthday!.month, 5);
      expect(full.birthday!.day, 17);
      expect(full.visitorsVisible, isTrue);
      expect(full.photos.single.mediaId, 'm1');
      expect(full.photos.single.height, 600);
      expect(full.reasons, ['interests', 'languages']);
    });

    test('a birthday reads as month and day, never a year', () {
      expect(birthdayText(const Birthday(5, 17)), 'May 17');
      expect(birthdayText(const Birthday(2, 29)), 'February 29');
      expect(birthdayText(const Birthday(2, 30)), isNull);
      expect(birthdayText(const Birthday(13, 1)), isNull);
      expect(birthdayText(null), isNull);
      expect(birthdayText(const Birthday(12, 31)), isNot(contains('20')));
    });

    test('a hometown is never an address', () {
      for (final bad in [
        '12 Baker Street',
        'Flat 4',
        'Plot 12',
        'near 1234',
        'home #4',
        'me@example.test',
        'PO Box 7',
      ]) {
        expect(looksLikeAddress(bad), isTrue, reason: bad);
      }
      for (final ok in ['Lisbon', 'São Paulo', 'Pune', 'Saint-Étienne']) {
        expect(looksLikeAddress(ok), isFalse, reason: ok);
      }
      expect(maxMinorHometown, lessThan(maxHometown));
      expect(maxProfileLanguages, 5);
      expect(maxProfileInterests, 10);
      expect(maxAboutMe, 160);
    });
  });

  group('people filters', () {
    test('the new filters count, compare and serialise', () {
      final f = PeopleFilters(
        languages: ['ko'],
        languageMinLevel: 4,
        personalityTags: ['curious', 'maker'],
        sameCountry: true,
      );
      expect(f.isEmpty, isFalse);
      // one language, the level, two tags and the country shortcut
      expect(f.count, 1 + 1 + 2 + 1);
      expect(f.toJson(), containsPair('languageMinLevel', 4));
      expect(f.toJson(), containsPair('personalityTags', ['curious', 'maker']));
      expect(f.toJson(), containsPair('sameCountry', true));
      expect(
        f.sameAs(
          PeopleFilters(
            languages: ['ko'],
            languageMinLevel: 4,
            personalityTags: ['maker', 'curious'],
            sameCountry: true,
          ),
        ),
        isTrue,
      );
      expect(f.sameAs(f.copyWith(languageMinLevel: 5)), isFalse);
    });

    test('a level without a language is not sent', () {
      expect(
        PeopleFilters(languageMinLevel: 4)
            .toJson()
            .containsKey('languageMinLevel'),
        isFalse,
      );
    });

    test(
      'the possible matches mode is a mode: not a search field, not saved',
      () {
        final f = PeopleFilters(possible: true);
        expect(f.isEmpty, isFalse);
        expect(f.toJson().keys, isNot(contains('possible')));
        expect(f.toSaved().keys, isNot(contains('possible')));
        expect(
          PeopleFilters(nearby: true).toSaved().keys,
          isNot(contains('nearby')),
        );
      },
    );

    test('saved filters round trip and survive junk', () {
      final f = PeopleFilters(
        interests: ['Music'],
        languages: ['ko', 'en'],
        languageMinLevel: 3,
        personalityTags: ['maker'],
        country: 'IN',
        online: true,
        ageMin: 18,
        gender: 'woman',
      );
      expect(PeopleFilters.fromSaved(f.toSaved()).sameAs(f), isTrue);
      expect(PeopleFilters.fromSaved(null).isEmpty, isTrue);
      expect(PeopleFilters.fromSaved('junk').isEmpty, isTrue);
      expect(
        PeopleFilters.fromSaved({
          'interests': [1, 'ok', null],
          'languageMinLevel': 99,
        }).languageMinLevel,
        6,
      );
    });
  });

  group('local time', () {
    final info = const LocalTimeInfo(330, 'UTC+5:30');
    test('the member\'s wall clock is the UTC clock moved by their offset', () {
      final now = DateTime.utc(2026, 10, 18, 10, 12);
      expect(localTimeThere(info, now).hour, 15);
      expect(localTimeThere(info, now).minute, 42);
      expect(formatLocalTime(info, now), '3:42 PM');
      expect(formatLocalTime(info, now, use24Hour: true), '15:42');
    });

    test('a negative offset and a day change', () {
      final ny = const LocalTimeInfo(-240, 'UTC-4');
      final now = DateTime.utc(2026, 7, 15, 2, 5);
      expect(localTimeThere(ny, now).day, 14);
      expect(formatLocalTime(ny, now), '10:05 PM');
    });

    test('daylight saving: the same zone has two offsets in a year', () {
      // The server sends the offset for now; the app only adds it. London in January and July.
      const winter = LocalTimeInfo(0, 'UTC');
      const summer = LocalTimeInfo(60, 'UTC+1');
      final noon = DateTime.utc(2026, 1, 15, 12);
      final july = DateTime.utc(2026, 7, 15, 12);
      expect(formatLocalTime(winter, noon), '12:00 PM');
      expect(formatLocalTime(summer, july), '1:00 PM');
    });

    test('the difference from this phone is said in words', () {
      final local = DateTime(2026, 10, 18, 12);
      final offset = local.timeZoneOffset.inMinutes;
      expect(localTimeDifference(LocalTimeInfo(offset, 'x'), local), isNull);
      expect(
        localTimeDifference(LocalTimeInfo(offset + 180, 'x'), local),
        '3 hours ahead',
      );
      expect(
        localTimeDifference(LocalTimeInfo(offset - 30, 'x'), local),
        '30 minutes behind',
      );
      expect(
        localTimeDifference(LocalTimeInfo(offset + 60, 'x'), local),
        '1 hour ahead',
      );
    });

    test('the clock ticks exactly on the minute', () {
      expect(
        untilNextMinute(DateTime.utc(2026, 1, 1, 10, 0, 15, 250)),
        const Duration(seconds: 44, milliseconds: 750),
      );
      expect(
        untilNextMinute(DateTime.utc(2026, 1, 1, 10, 0, 0)),
        const Duration(seconds: 60),
      );
    });
  });

  group('device prefs', () {
    test('saved filters and dismissed tips are kept per account', () async {
      final store = MemoryDiscoverPrefsStore();
      await store.saveFilters('a', PeopleFilters(interests: ['Music']));
      await store.dismissTip('a', 'discover.possible_matches');
      expect((await store.savedFilters('a'))!.interests, ['Music']);
      expect(await store.savedFilters('b'), isNull);
      expect(await store.dismissedTips('a'), {'discover.possible_matches'});
      expect(await store.dismissedTips('b'), isEmpty);
      await store.forget('a');
      expect(await store.savedFilters('a'), isNull);
      expect(await store.dismissedTips('a'), isEmpty);
    });

    test('saving an empty selection clears what was saved', () async {
      final store = MemoryDiscoverPrefsStore();
      await store.saveFilters('a', PeopleFilters(online: true));
      await store.saveFilters('a', PeopleFilters());
      expect(await store.savedFilters('a'), isNull);
    });

    test(
      'a dismissed tip stays dismissed and is read before it can show',
      () async {
        final store = MemoryDiscoverPrefsStore();
        await store.dismissTip(anjaliUser, 'home.people_you_may_like');
        final container = ProviderContainer(
          overrides: [
            discoverPrefsStoreProvider.overrideWithValue(store),
            sessionProvider.overrideWith(SignedIn.new),
          ],
        );
        addTearDown(container.dispose);
        // Unknown until the saved set has been read.
        expect(container.read(dismissedTipsProvider), isNull);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(container.read(dismissedTipsProvider), {
          'home.people_you_may_like',
        });
        await container.read(dismissedTipsProvider.notifier).dismiss('x');
        expect(container.read(dismissedTipsProvider), contains('x'));
        expect(await store.dismissedTips(anjaliUser), contains('x'));
      },
    );
  });
}

const anjaliUser = '019a4000-0000-7000-8000-000000000001';
