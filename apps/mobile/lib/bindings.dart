import 'package:flutter_riverpod/misc.dart' show Override;

import 'app.dart' show routerProvider;
import 'core/app_bindings.dart';
import 'core/chat/chat_store.dart' show ChatStore;
import 'features/chat.dart'
    show SecureChatStore, chatEngineProvider, chatSupported;
import 'features/shop/locked_feature_sheet.dart' show showLockedFeatureSheet;

/// Fills the seams in `core/app_bindings.dart` with the real app. The only
/// place that knows both sides; `main` installs it on the root scope.
List<Override> appBindings() => [
  chatWipeStoreProvider.overrideWith(
    (ref) => chatWipeStoreWhere(chatSupported, SecureChatStore.new),
  ),
  chatEngineSourceProvider.overrideWith(
    (ref) => ref.watch(chatEngineProvider.future),
  ),
  premiumRequiredHandlerProvider.overrideWith(
    (ref) =>
        (context, feature) => showLockedFeatureSheet(context, feature: feature),
  ),
  routeOpenerProvider.overrideWith(
    (ref) =>
        (location) => ref.read(routerProvider).go(location),
  ),
];

/// The keystore the sign-out wipe uses, or null where chat does not exist (the web and
/// desktop builds have no chat keys to erase, and reading a keystore there only
/// produces error reports). [supported] is `chatSupported`.
ChatStore? chatWipeStoreWhere(bool supported, ChatStore Function() open) =>
    supported ? open() : null;
