import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat/chat_engine.dart' show ChatEngine;
import 'chat/chat_store.dart' show ChatStore;

/// Seams that let `core` use things the app shell owns without importing the
/// shell or the feature screens. `lib/bindings.dart` fills them in for the app;
/// until then they do nothing, which is what a test that never opens a
/// screen or a chat wants.

/// The signed-in member's chat engine, or null where there is none.
///
/// Bound to the chat feature's own provider in `lib/bindings.dart`. When the
/// feature's provider moves into core, this one goes away.
final chatEngineSourceProvider = FutureProvider<ChatEngine?>(
  (ref) async => null,
);

/// Opens an in-app location (`/chats`, `/profile`, ...), like a tapped link.
final routeOpenerProvider = Provider<void Function(String location)>(
  (ref) => (location) {},
);

/// The keystore the chat keeps its keys and history in, for the sign-out wipe
/// (`chat_wipe_hook.dart`). Null (nothing to wipe) until `lib/bindings.dart`
/// binds the platform keystore.
final chatWipeStoreProvider = Provider<ChatStore?>((ref) => null);

/// Explains a Premium feature (the sheet of the shop feature) when the server answers 402 PREMIUM_REQUIRED; null (a plain message) until
/// `lib/bindings.dart` binds it.
final premiumRequiredHandlerProvider =
    Provider<void Function(BuildContext context, String feature)?>(
      (ref) => null,
    );
