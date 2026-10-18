import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared/widgets.dart' show showMessage;
import 'api.dart';
import 'app_bindings.dart' show premiumRequiredHandlerProvider;
import 'auth/auth_gateway.dart';
import 'error_reporting.dart';

/// Shown when a failure has no wording written for people.
const genericFailure = 'Something went wrong. Try again.';

/// The words to show for [error]. Known failures (the API's mapped messages,
/// the identity provider's) keep their wording; anything else, such as a
/// parsing bug, gets [genericFailure] and is sent to error reporting instead
/// of putting Dart's `toString()` on screen.
String friendlyError(Object? error, {StackTrace? stack}) {
  switch (error) {
    case ApiFailure():
      return error.displayMessage;
    case AuthFailure(:final message):
      return message;
    case String():
      // Already worded: screens keep the text [friendlyError] returned earlier.
      return error;
    case null:
      return genericFailure;
  }
  ErrorReporting.capture(error, stack ?? StackTrace.current);
  return genericFailure;
}

/// A snack bar for a failed action, worded by [friendlyError].
///
/// A 402 PREMIUM_REQUIRED (the server sends it only to an adult whose plan lacks the feature, while plans are enforced) opens the sheet that explains
/// Premium instead, when the app has bound one (`lib/bindings.dart`).
void showFailure(BuildContext context, Object error, [StackTrace? stack]) {
  if (error is ApiFailureDetails && error.code == 'PREMIUM_REQUIRED') {
    final feature = error.details['feature'];
    final open = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(premiumRequiredHandlerProvider);
    if (open != null && feature is String) {
      open(context, feature);
      return;
    }
  }
  showMessage(context, friendlyError(error, stack: stack));
}
