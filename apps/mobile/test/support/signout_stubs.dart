/// Memory stand-ins for everything the sign-out clean-up touches, for tests that sign out with the
/// real `SessionController`. Without them the clean-up would wait on a platform keystore and image
/// cache that do not exist under `flutter test` (and be cut off by the hook time limit).
library;

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:hiyall/core/home_prefs.dart';
import 'package:hiyall/core/push/push_prefs.dart';
import 'package:hiyall/core/say_hi_prefs.dart';
import 'package:hiyall/core/signout_residue.dart';
import 'package:hiyall/core/story_draft.dart';

List<Override> signOutStubs() => [
  storyDraftStoreProvider.overrideWithValue(MemoryStoryDraftStore()),
  homePrefsStoreProvider.overrideWithValue(MemoryHomePrefsStore()),
  sayHiPrefsStoreProvider.overrideWithValue(MemorySayHiPrefsStore()),
  pushPrefsStoreProvider.overrideWithValue(MemoryPushPrefsStore()),
  imageCachesWipeProvider.overrideWithValue(() async {}),
];
