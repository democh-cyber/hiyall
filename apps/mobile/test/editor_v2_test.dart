import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/avatar_upload.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/shared/language_chip.dart';

import 'avatar_helpers.dart';
import 'support/fixtures.dart';
import 'widget_test.dart' show FakeApi, SignedIn;

/// A server for the profile editor: the profile, the privacy settings, the gallery and what was sent.
class EditorApi extends FakeApi {
  bool minor = false;
  int version = 1;
  int privacyVersion = 1;
  List<ProfileLanguage> languages = [const ProfileLanguage('en', 4)];
  List<String> tags = [];
  List<String> interests = ['Music'];
  String aboutMe = '', hometown = '';
  Map<String, String> audiences = {};
  final saves = <Map<String, dynamic>>[];
  final privacyPatches = <Map<String, dynamic>>[];
  var photosList = <GalleryPhoto>[];
  int max = 8;
  int uploads = 0;
  Object? addFailure;
  Object? uploadFailure;
  final galleryCalls = <String>[];

  @override
  Future<NearbyStatus> nearbyStatus(Session s) async =>
      NearbyStatus(minor: minor);

  Profile get current => Profile(
    userId: anjaliId,
    username: 'anjali',
    displayName: 'Anjali',
    bio: 'hello',
    profession: '',
    version: '$version',
    languages: languages,
    personalityTags: tags,
    interests: interests,
    aboutMe: aboutMe,
    hometown: hometown,
    avatarUrl: photosList.isEmpty ? null : photosList.first.thumbUrl,
    photos: photosList,
  );

  @override
  Future<Profile> profile(Session s) async => current;

  @override
  Future<Profile> updateProfile(
    Session s,
    Profile p,
    Map<String, dynamic> patch,
  ) async {
    saves.add(patch);
    version++;
    if (patch['languages'] != null) {
      languages = [
        for (final l in patch['languages'] as List)
          ProfileLanguage.fromJson(l as Object),
      ];
    }
    if (patch['personalityTags'] != null) {
      tags = List<String>.from(patch['personalityTags'] as List);
    }
    if (patch['aboutMe'] != null) aboutMe = patch['aboutMe'] as String;
    if (patch['hometown'] != null) hometown = patch['hometown'] as String;
    return current;
  }

  @override
  Future<Privacy> privacy(Session s) async => Privacy({
    'version': '$privacyVersion',
    'fieldAudiences': {...audiences},
    'onlineAudience': 'everyone',
  });

  @override
  Future<Privacy> updatePrivacy(
    Session s,
    Privacy p,
    Map<String, dynamic> patch,
  ) async {
    privacyPatches.add(patch);
    privacyVersion++;
    final fields = patch['fieldAudiences'] as Map?;
    if (fields != null) {
      audiences.addAll({
        for (final e in fields.entries) e.key as String: e.value as String,
      });
    }
    return privacy(s);
  }

  @override
  Future<Gallery> gallery(Session s) async => Gallery(photosList, max);

  @override
  Future<String> uploadPhoto(
    Session s,
    Uint8List bytes, {
    required String contentType,
    required String purpose,
    void Function(double progress)? onProgress,
  }) async {
    if (uploadFailure != null) throw uploadFailure!;
    galleryCalls.add('upload $purpose');
    return 'up-${++uploads}';
  }

  GalleryPhoto _photo(String id) => GalleryPhoto(
    id,
    'https://cdn.test/$id/full.jpg',
    'https://cdn.test/$id/t.jpg',
    800,
    600,
  );

  @override
  Future<Gallery> addGalleryPhoto(Session s, String mediaId) async {
    if (addFailure != null) throw addFailure!;
    galleryCalls.add('add $mediaId');
    photosList = [...photosList, _photo(mediaId)];
    return Gallery(photosList, max);
  }

  @override
  Future<Gallery> replaceGalleryPhoto(
    Session s,
    String id,
    String newId,
  ) async {
    galleryCalls.add('replace $id $newId');
    photosList = [
      for (final p in photosList) p.mediaId == id ? _photo(newId) : p,
    ];
    return Gallery(photosList, max);
  }

  @override
  Future<Gallery> deleteGalleryPhoto(Session s, String id) async {
    galleryCalls.add('delete $id');
    photosList = [
      for (final p in photosList)
        if (p.mediaId != id) p,
    ];
    return Gallery(photosList, max);
  }

  @override
  Future<Gallery> reorderGallery(Session s, List<String> ids) async {
    galleryCalls.add('order ${ids.join(',')}');
    photosList = [
      for (final id in ids) photosList.firstWhere((p) => p.mediaId == id),
    ];
    version++;
    return Gallery(photosList, max);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final family in ['SpaceGrotesk', 'Manrope']) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  late AvatarRequests requests;
  setUp(() => requests = AvatarRequests(() => const BrokenImage()));
  tearDown(AvatarRequests.restore);

  late ProviderContainer container;
  Future<void> open(
    WidgetTester tester,
    EditorApi api, {
    Size size = const Size(390, 1600),
    double scale = 1,
    PhotoPicker? picker,
    TextDirection? dir,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    container = ProviderContainer(
      overrides: <Override>[
        apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(SignedIn.new),
        imagePickerProvider.overrideWithValue(
          picker ?? (PhotoPicker()..bytes = pngBytes),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: scale == 1 && dir == null
            ? const HiyallApp()
            : MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                ),
                child: Directionality(
                  textDirection: dir ?? TextDirection.ltr,
                  child: const HiyallApp(),
                ),
              ),
      ),
    );
    container.read(routerProvider).go('/profile/edit');
    await tester.pumpAndSettle();
  }

  /// Scrolls [target] into view and a little past the floating dock at the bottom, so a tap lands on it.
  Future<void> reveal(WidgetTester tester, Finder target) async {
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(target, 300, scrollable: scrollable);
    await Scrollable.ensureVisible(tester.element(target), alignment: .3);
    await tester.pumpAndSettle();
  }

  /// The camera is offered on phones: pick "from gallery" in the sheet that asks.
  Future<void> fromGallery(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('photos-pick-gallery')));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await reveal(tester, find.text('Save profile'));
    await tester.tap(find.text('Save profile'));
    await tester.pumpAndSettle();
  }

  group('languages', () {
    testWidgets(
      'each shows its level and a way to change it; the count is visible',
      (tester) async {
        final api = EditorApi();
        await open(tester, api);
        await reveal(tester, find.byKey(const Key('add-language')));
        expect(find.text('Fluent'), findsWidgets);
        expect(find.byKey(const Key('languages-count')), findsOneWidget);
        expect(find.text('1 of $maxLanguagesShown'), findsOneWidget);
        final handle = tester.ensureSemantics();
        expect(
          find.bySemanticsLabel('English, fluent. Change level.'),
          findsOneWidget,
        );
        handle.dispose();
      },
    );

    testWidgets(
      'changing a level uses the six-level sheet and is saved as a number',
      (tester) async {
        final api = EditorApi();
        await open(tester, api);
        await reveal(tester, find.byKey(const Key('level-en')));
        await tester.tap(find.byKey(const Key('level-en')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('level-sheet')), findsOneWidget);
        for (var i = 1; i <= 6; i++) {
          expect(find.byKey(Key('level-$i')), findsOneWidget);
        }
        expect(find.text('Just starting'), findsOneWidget);
        expect(find.text('Native'), findsOneWidget);
        await tester.tap(find.byKey(const Key('level-6')));
        await tester.pumpAndSettle();
        await save(tester);
        expect(api.saves.single['languages'], [
          {'code': 'en', 'level': 6},
        ]);
      },
    );

    testWidgets('adding a language asks for its level in the same flow', (
      tester,
    ) async {
      final api = EditorApi();
      await open(tester, api);
      await reveal(tester, find.byKey(const Key('add-language')));
      await tester.tap(find.byKey(const Key('add-language')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'korean');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Korean').first);
      await tester.pumpAndSettle();
      // The level sheet starts on Conversational.
      expect(find.byKey(const Key('level-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('level-2')));
      await tester.pumpAndSettle();
      expect(find.text('2 of 5'), findsOneWidget);
      await save(tester);
      expect(api.saves.single['languages'], [
        {'code': 'en', 'level': 4},
        {'code': 'ko', 'level': 2},
      ]);
    });

    testWidgets('five is the most: the add button is off at the limit', (
      tester,
    ) async {
      final api = EditorApi()
        ..languages = [
          for (final c in ['en', 'hi', 'ko', 'ja', 'es']) ProfileLanguage(c, 3),
        ];
      await open(tester, api);
      await reveal(tester, find.byKey(const Key('add-language')));
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('add-language')))
            .onPressed,
        isNull,
      );
      expect(find.text('5 of 5'), findsOneWidget);
    });

    testWidgets('the level meter is part of each row', (tester) async {
      await open(tester, EditorApi());
      await reveal(tester, find.byKey(const Key('add-language')));
      expect(find.byType(LevelMeter), findsWidgets);
    });
  });

  group('personality tags', () {
    testWidgets('three to five can be chosen, a sixth cannot', (tester) async {
      final api = EditorApi();
      await open(tester, api);
      await reveal(tester, find.byKey(const Key('tag-curious')));
      for (final id in ['curious', 'maker', 'foodie', 'playful', 'sporty']) {
        await reveal(tester, find.byKey(Key('tag-$id')));
        await tester.tap(find.byKey(Key('tag-$id')));
        await tester.pump();
      }
      expect(
        find.text('5 of 5 chosen. Remove one to pick another.'),
        findsOneWidget,
      );
      // A sixth is not accepted: its chip is off.
      await reveal(tester, find.byKey(const Key('tag-chatty')));
      await tester.tap(find.byKey(const Key('tag-chatty')));
      await tester.pump();
      expect(
        find.text('5 of 5 chosen. Remove one to pick another.'),
        findsOneWidget,
      );
      await save(tester);
      expect(api.saves.single['personalityTags'], [
        'curious',
        'maker',
        'foodie',
        'playful',
        'sporty',
      ]);
    });

    testWidgets('one or two wait: Save is off and says why; none is fine', (
      tester,
    ) async {
      final api = EditorApi();
      await open(tester, api);
      await reveal(tester, find.byKey(const Key('tag-curious')));
      await tester.tap(find.byKey(const Key('tag-curious')));
      await tester.pump();
      await reveal(tester, find.text('Save profile'));
      expect(find.byKey(const Key('save-waiting')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save profile'),
            )
            .onPressed,
        isNull,
      );
      // Back to none.
      await reveal(tester, find.byKey(const Key('tag-curious')));
      await tester.tap(find.byKey(const Key('tag-curious')));
      await tester.pump();
      await reveal(tester, find.text('Save profile'));
      expect(find.byKey(const Key('save-waiting')), findsNothing);
      await tester.tap(find.text('Save profile'));
      await tester.pumpAndSettle();
      expect(api.saves.single['personalityTags'], isEmpty);
    });

    testWidgets('a chip is selected state for a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, EditorApi()..tags = ['curious', 'maker', 'foodie']);
      await reveal(tester, find.byKey(const Key('tag-curious')));
      expect(
        tester
            .getSemantics(find.byKey(const Key('tag-curious')))
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      handle.dispose();
    });
  });

  group('about me and hometown', () {
    testWidgets('an address is refused where it is typed, nothing is sent', (
      tester,
    ) async {
      final api = EditorApi();
      await open(tester, api);
      await reveal(tester, find.text('Hometown or city'));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Hometown or city'),
        '12 Baker Street',
      );
      await reveal(tester, find.text('Save profile'));
      await tester.tap(find.text('Save profile'));
      await tester.pumpAndSettle();
      expect(
        find.text('Write a town or city, not an address.'),
        findsOneWidget,
      );
      expect(api.saves, isEmpty);
    });

    testWidgets('a town is saved with about me', (tester) async {
      final api = EditorApi();
      await open(tester, api);
      await reveal(tester, find.text('A line about you'));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'A line about you'),
        'Slow mornings',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Hometown or city'),
        'Lisbon',
      );
      await save(tester);
      expect(api.saves.single['aboutMe'], 'Slow mornings');
      expect(api.saves.single['hometown'], 'Lisbon');
    });

    testWidgets('adult: 80 characters, audiences from everyone to only me', (
      tester,
    ) async {
      final api = EditorApi();
      await open(tester, api);
      await reveal(tester, find.text('Hometown or city'));
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.widgetWithText(TextFormField, 'Hometown or city'),
          matching: find.byType(TextField),
        ),
      );
      expect(field.maxLength, 80);
      await reveal(tester, find.byKey(const Key('audience-hometown')));
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('audience-hometown')),
          matching: find.byType(OutlinedButton),
        ),
      );
      await tester.pumpAndSettle();
      for (final option in ['everyone', 'followers', 'friends', 'nobody']) {
        expect(find.byKey(Key('audience-$option')), findsOneWidget);
      }
    });

    testWidgets(
      'minor: 40 characters, a friends-only note, and no audience wider than friends',
      (tester) async {
        final api = EditorApi()..minor = true;
        await open(tester, api);
        await reveal(tester, find.text('Hometown or city'));
        final field = tester.widget<TextField>(
          find.descendant(
            of: find.widgetWithText(TextFormField, 'Hometown or city'),
            matching: find.byType(TextField),
          ),
        );
        expect(field.maxLength, 40);
        expect(
          find.textContaining('Only your friends can see this'),
          findsOneWidget,
        );
        await reveal(tester, find.byKey(const Key('audience-hometown')));
        // Hidden by default.
        expect(find.text('Only me'), findsWidgets);
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('audience-hometown')),
            matching: find.byType(OutlinedButton),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('audience-nobody')), findsOneWidget);
        expect(find.byKey(const Key('audience-friends')), findsOneWidget);
        expect(find.byKey(const Key('audience-everyone')), findsNothing);
        expect(find.byKey(const Key('audience-followers')), findsNothing);
      },
    );

    testWidgets(
      'a changed audience is saved to the privacy settings after the profile',
      (tester) async {
        final api = EditorApi()..minor = true;
        await open(tester, api);
        await reveal(tester, find.byKey(const Key('audience-hometown')));
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('audience-hometown')),
            matching: find.byType(OutlinedButton),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('audience-friends')));
        await tester.pumpAndSettle();
        await save(tester);
        expect(api.saves, hasLength(1));
        expect(api.privacyPatches.single, {
          'fieldAudiences': {'hometown': 'friends'},
        });
      },
    );

    testWidgets('an untouched audience sends nothing to privacy', (
      tester,
    ) async {
      final api = EditorApi();
      await open(tester, api);
      await save(tester);
      expect(api.privacyPatches, isEmpty);
    });
  });

  group('photos', () {
    List<GalleryPhoto> three() => [
      for (final id in ['m1', 'm2', 'm3'])
        GalleryPhoto(
          id,
          'https://cdn.test/$id/full.jpg',
          'https://cdn.test/$id/t.jpg',
          800,
          600,
        ),
    ];

    testWidgets(
      'the gallery shows in order; the first is the profile photo; the counter says how many',
      (tester) async {
        final handle = tester.ensureSemantics();
        await open(tester, EditorApi()..photosList = three());
        await reveal(tester, find.byKey(const Key('photos-grid')));
        expect(find.byKey(const ValueKey('photo-m1')), findsOneWidget);
        expect(find.text('3 of 8'), findsOneWidget);
        expect(find.text('Profile'), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp('Profile photo, photo 1 of 3')),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(RegExp('Photo 2 of 3')), findsOneWidget);
        expect(requests.keys, contains('photo:m2:thumb'));
        handle.dispose();
      },
    );

    testWidgets(
      'adding uploads as an avatar photo, then adds it to the gallery',
      (tester) async {
        final api = EditorApi()..photosList = three();
        await open(tester, api);
        await reveal(tester, find.byKey(const Key('photos-add')));
        await tester.tap(find.byKey(const Key('photos-add')));
        await tester.pumpAndSettle();
        await fromGallery(tester);
        // On a desktop the gallery opens straight away (no camera to choose).
        expect(api.galleryCalls, ['upload avatar', 'add up-1']);
        expect(find.text('4 of 8'), findsOneWidget);
      },
    );

    testWidgets('a full gallery has no add tile', (tester) async {
      final api = EditorApi()
        ..max = 3
        ..photosList = three();
      await open(tester, api);
      await reveal(tester, find.byKey(const Key('photos-grid')));
      expect(find.byKey(const Key('photos-add')), findsNothing);
      expect(find.text('3 of 3'), findsOneWidget);
    });

    testWidgets('the server saying PHOTOS_FULL is said calmly', (tester) async {
      final api = EditorApi()
        ..photosList = three()
        ..addFailure = const ApiFailure(
          'You’ve reached the photo limit.',
          409,
          'PHOTOS_FULL',
        );
      await open(tester, api);
      await reveal(tester, find.byKey(const Key('photos-add')));
      await tester.tap(find.byKey(const Key('photos-add')));
      await tester.pumpAndSettle();
      await fromGallery(tester);
      expect(find.byKey(const Key('photos-error')), findsOneWidget);
      expect(find.textContaining('Remove one to add another'), findsOneWidget);
    });

    testWidgets(
      'a photo the scanner did not pass says only that it cannot be used',
      (tester) async {
        final api = EditorApi()
          ..addFailure = const ApiFailure('Photo not ready', 422, 'VALIDATION');
        await open(tester, api);
        await reveal(tester, find.byKey(const Key('photos-add')));
        await tester.tap(find.byKey(const Key('photos-add')));
        await tester.pumpAndSettle();
        await fromGallery(tester);
        expect(
          find.text('That photo can’t be used. Try another one.'),
          findsOneWidget,
        );
        expect(find.textContaining('scan'), findsNothing);
        expect(find.textContaining('quarantin'), findsNothing);
      },
    );

    testWidgets(
      'delete asks first; removing the first makes the next the profile photo',
      (tester) async {
        final api = EditorApi()..photosList = three();
        await open(tester, api);
        await reveal(tester, find.byKey(const ValueKey('photo-m1')));
        await tester.tap(find.byKey(const ValueKey('photo-m1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('photo-remove')));
        await tester.pumpAndSettle();
        expect(find.text('Remove this photo?'), findsOneWidget);
        expect(
          find.textContaining('next photo takes its place'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('confirm-cancel')));
        await tester.pumpAndSettle();
        expect(api.galleryCalls, isEmpty);
        await tester.tap(find.byKey(const ValueKey('photo-m1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('photo-remove')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-ok')));
        await tester.pumpAndSettle();
        expect(api.galleryCalls, ['delete m1']);
        expect(find.text('2 of 8'), findsOneWidget);
      },
    );

    testWidgets(
      'reordering works without dragging: make first, earlier, later',
      (tester) async {
        final api = EditorApi()..photosList = three();
        await open(tester, api);
        await reveal(tester, find.byKey(const ValueKey('photo-m3')));
        await tester.tap(find.byKey(const ValueKey('photo-m3')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('photo-later')),
          findsNothing,
        ); // last: nowhere later
        await tester.tap(find.byKey(const Key('photo-make-first')));
        await tester.pumpAndSettle();
        expect(api.galleryCalls.last, 'order m3,m1,m2');
        await tester.tap(find.byKey(const ValueKey('photo-m1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('photo-later')));
        await tester.pumpAndSettle();
        expect(api.galleryCalls.last, 'order m3,m2,m1');
        await tester.tap(find.byKey(const ValueKey('photo-m1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('photo-earlier')));
        await tester.pumpAndSettle();
        expect(api.galleryCalls.last, 'order m3,m1,m2');
      },
    );

    testWidgets('the same moves are offered to a screen reader as actions', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester, EditorApi()..photosList = three());
      await reveal(tester, find.byKey(const ValueKey('photo-m2')));
      final node = tester.getSemantics(find.byKey(const ValueKey('photo-m2')));
      final labels = [
        for (final id
            in node.getSemanticsData().customSemanticsActionIds ?? <int>[])
          CustomSemanticsAction.getAction(id)!.label,
      ];
      expect(
        labels,
        containsAll(['Make profile photo', 'Move earlier', 'Move later']),
      );
      handle.dispose();
    });

    testWidgets('replace keeps the place', (tester) async {
      final api = EditorApi()..photosList = three();
      await open(tester, api);
      await reveal(tester, find.byKey(const ValueKey('photo-m2')));
      await tester.tap(find.byKey(const ValueKey('photo-m2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-replace')));
      await tester.pumpAndSettle();
      await fromGallery(tester);
      expect(api.galleryCalls, ['upload avatar', 'replace m2 up-1']);
      expect(api.photosList.map((p) => p.mediaId), ['m1', 'up-1', 'm3']);
    });

    testWidgets('an upload that fails says so and offers a retry', (
      tester,
    ) async {
      final api = EditorApi()
        ..uploadFailure = const ApiFailure('Too big', 413, 'TOO_LARGE');
      await open(tester, api);
      await reveal(tester, find.byKey(const Key('photos-add')));
      await tester.tap(find.byKey(const Key('photos-add')));
      await tester.pumpAndSettle();
      await fromGallery(tester);
      expect(find.byKey(const Key('photos-error')), findsOneWidget);
    });
  });

  group('layout', () {
    for (final dir in [TextDirection.ltr, TextDirection.rtl]) {
      testWidgets('320 px wide at text scale 2.0 does not overflow ($dir)', (
        tester,
      ) async {
        final api = EditorApi()
          ..minor = true
          ..tags = ['curious', 'maker', 'foodie']
          ..photosList = [
            for (final id in ['m1', 'm2', 'm3'])
              GalleryPhoto(
                id,
                'https://cdn.test/$id/f.jpg',
                'https://cdn.test/$id/t.jpg',
              ),
          ];
        await open(tester, api, size: const Size(320, 900), scale: 2, dir: dir);
        for (final key in [
          const Key('photos-grid'),
          const Key('add-language'),
          const Key('tag-curious'),
          const Key('audience-hometown'),
        ]) {
          await reveal(tester, find.byKey(key));
          expect(tester.takeException(), isNull, reason: '$key');
        }
      });
    }
  });
}

const maxLanguagesShown = 5;
