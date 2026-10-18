import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Reading a message aloud, on the phone. The platform's own speech engine does the work; the text is handed
/// to it locally and never to a network service.
abstract class SpeechService {
  bool get supported;

  /// Reads [text] aloud in [language] (a BCP 47 code such as `de`, or null for the phone's language). Returns
  /// when it finished or was stopped. Throws [SpeechException] when no voice that works offline can read that
  /// language.
  Future<void> speak(String text, {String? language});

  Future<void> stop();
  Future<void> dispose() async {}
}

enum SpeechProblem {
  /// This phone has no speech engine.
  unsupported,

  /// No installed voice reads that language without the network. Nothing is sent anywhere to get one: the
  /// person installs a voice in the phone's own text-to-speech settings.
  noOfflineVoice,
  failed,
}

class SpeechException implements Exception {
  final SpeechProblem problem;
  const SpeechException(this.problem);
  @override
  String toString() => 'SpeechException(${problem.name})';
}

/// [SpeechService] over `flutter_tts`: Android's TextToSpeech and iOS's AVSpeechSynthesizer. A voice that needs
/// the network (some Android engines offer them) is never chosen: a chat message is private, and "on the
/// phone" has to mean on the phone. Device-only: needs a real engine.
class DeviceSpeechService implements SpeechService {
  FlutterTts? _tts;
  FlutterTts get _engine => _tts ??= FlutterTts();
  bool _configured = false;

  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _setup() async {
    if (_configured) return;
    _configured = true;
    await _engine.awaitSpeakCompletion(true);
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _engine.setSharedInstance(true);
    }
  }

  /// The first voice for [language] that does not need the network (iOS voices all run on the phone and carry
  /// no such flag), or null.
  static Map<String, String>? pickOfflineVoice(
    List<dynamic> voices,
    String language,
  ) {
    for (final v in voices) {
      if (v is! Map) continue;
      final locale = '${v['locale']}'.replaceAll('_', '-').toLowerCase();
      if (locale != language && !locale.startsWith('$language-')) continue;
      final needsNetwork = '${v['network_required']}' == '1';
      if (needsNetwork) continue;
      final name = v['name'], loc = v['locale'];
      if (name is String && loc is String) {
        return {'name': name, 'locale': loc};
      }
    }
    return null;
  }

  @override
  Future<void> speak(String text, {String? language}) async {
    if (!supported) throw const SpeechException(SpeechProblem.unsupported);
    try {
      await _setup();
      final code = (language ?? PlatformDispatcher.instance.locale.languageCode)
          .toLowerCase();
      final voices = await _engine.getVoices;
      final voice = voices is List ? pickOfflineVoice(voices, code) : null;
      if (voice == null) {
        throw const SpeechException(SpeechProblem.noOfflineVoice);
      }
      await _engine.setVoice(voice);
      await _engine.speak(text);
    } on SpeechException {
      rethrow;
    } catch (_) {
      throw const SpeechException(SpeechProblem.failed);
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() => stop();
}

/// For tests: records what was spoken and can be told to refuse.
class FakeSpeechService implements SpeechService {
  FakeSpeechService({this.isSupported = true, this.offlineVoice = true});
  final bool isSupported, offlineVoice;
  final spoken = <({String text, String? language})>[];
  int stops = 0;

  /// Completes the pending `speak` when set.
  Completer<void>? finishing;

  @override
  bool get supported => isSupported;

  @override
  Future<void> speak(String text, {String? language}) async {
    if (!isSupported) throw const SpeechException(SpeechProblem.unsupported);
    if (!offlineVoice) {
      throw const SpeechException(SpeechProblem.noOfflineVoice);
    }
    spoken.add((text: text, language: language));
    await finishing?.future;
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async {}
}
