import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/auth/firebase_config.dart';
import 'core/error_reporting.dart';
import 'core/licenses.dart';
import 'core/push/push_service.dart' show registerPushBackgroundHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Error reporting first, so a failure while starting anything else is seen.
  await ErrorReporting.start(() async {
    // Never throws: a bad Firebase configuration leaves the app on Welcome
    // with "sign-in isn't set up", not a blank screen.
    final firebaseUp = await FirebaseConfig.initialize();
    if (firebaseUp) {
      try {
        registerPushBackgroundHandler();
      } catch (error, stack) {
        ErrorReporting.capture(error, stack);
      }
    }
    registerAppLicenses();
    runApp(const ProviderScope(child: HiyallApp()));
  });
}
