import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart'
    show CachedNetworkImageProvider;
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'home_prefs.dart';
import 'push/push_prefs.dart';
import 'say_hi_prefs.dart';
import 'story_draft.dart';

/// Empties the pictures this phone kept from the network (profile photos, post and
/// story images): the disk cache of `cached_network_image` and Flutter's decoded
/// copies in memory. Replaced by a fake in tests.
final imageCachesWipeProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    // The manager every CachedNetworkImage here uses (a DefaultCacheManager). Not awaited: it runs
    // on the cache's own database queue, sign-out has no reason to wait for it, and where there is
    // no database (tests) the call never answers.
    unawaited(
      CachedNetworkImageProvider.defaultCacheManager.emptyCache().then<void>(
        (_) {},
        onError: (_) {},
      ),
    );
  },
);

/// What a departing account leaves on this phone besides chat data (see
/// `chat_wipe_hook.dart` for that): its unsent story draft, the Home, Say hi and
/// notification choices kept for it, and every cached picture (the cache is shared by
/// all accounts, so it goes whole). Each step is best effort and never stops the
/// next. [userId] is the account that is leaving, or null when none is known: only
/// the shared picture caches are cleared then.
Future<void> Function() accountResidueHook(
  Ref ref,
  String? Function() userId,
) => () async {
  final uid = userId();
  Future<void> step(Future<void> Function() work) async {
    try {
      await work();
    } catch (_) {
      // Left for the next sign-out; nothing here may keep the person signed in.
    }
  }

  if (uid != null) {
    await step(() => ref.read(storyDraftStoreProvider).forget(uid));
    await step(() => ref.read(homePrefsStoreProvider).forget(uid));
    await step(() => ref.read(sayHiPrefsStoreProvider).forget(uid));
    await step(() => ref.read(pushPrefsStoreProvider).forget(uid));
  }
  await step(() => ref.read(imageCachesWipeProvider)());
};
