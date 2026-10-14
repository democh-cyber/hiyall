import 'package:flutter_riverpod/misc.dart' show Override;

import 'app.dart' show routerProvider;
import 'core/app_bindings.dart';
import 'features/chat.dart' show chatEngineProvider;

/// Fills the seams in `core/app_bindings.dart` with the real app. The only
/// place that knows both sides; `main` installs it on the root scope.
List<Override> appBindings() => [
  chatEngineSourceProvider.overrideWith(
    (ref) => ref.watch(chatEngineProvider.future),
  ),
  routeOpenerProvider.overrideWith(
    (ref) =>
        (location) => ref.read(routerProvider).go(location),
  ),
];
