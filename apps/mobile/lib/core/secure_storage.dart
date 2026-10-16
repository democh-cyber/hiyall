import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one place a [FlutterSecureStorage] is made, so every store in the app gets the same Android settings.
///
/// `resetOnError: false` matters. The plugin's default on Android is to erase everything it holds as soon as a
/// read fails (a keystore that is busy, locked or briefly unavailable looks like a lost key), and the chat engine
/// would then make a new key and start with no history and a new identity. With it off, a failed read surfaces as
/// an error, nothing is deleted, and the caller can try again (see [ChatStorageUnavailable] and the explicit
/// "Reset chat on this phone" action). Other stores hold small preferences whose readers already treat an
/// error as "not set".
///
/// [iOptions] is for the chat store, whose items are readable after the first unlock and never leave this
/// device. Everything else keeps the plugin's default Keychain accessibility.
FlutterSecureStorage createSecureStorage({
  IOSOptions iOptions = IOSOptions.defaultOptions,
}) => FlutterSecureStorage(
  iOptions: iOptions,
  aOptions: const AndroidOptions(resetOnError: false),
);
