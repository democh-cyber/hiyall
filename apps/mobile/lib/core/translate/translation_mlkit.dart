import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'translation_service.dart';

/// [TranslationService] over Google ML Kit's on-device translation and language identification (Android and
/// iOS). The models run on the phone; the text is handed to a local library and never to a network. The only
/// request is the one-time model download, which sends no text. Verified in unit tests with a fake: the plugin
/// itself needs a phone.
class MlKitTranslationService extends TranslationService {
  OnDeviceTranslatorModelManager? _models;
  OnDeviceTranslatorModelManager get _manager =>
      _models ??= OnDeviceTranslatorModelManager();
  LanguageIdentifier? _identifier;
  final _translators = <String, OnDeviceTranslator>{};

  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<Set<String>> installedPacks() async {
    if (!supported) return {builtInLanguage};
    final out = <String>{builtInLanguage};
    for (final l in translationLanguages) {
      if (l.code == builtInLanguage) continue;
      try {
        if (await _manager.isModelDownloaded(l.code)) out.add(l.code);
      } catch (_) {
        // A model that cannot be checked counts as not installed.
      }
    }
    return out;
  }

  @override
  Future<void> downloadPack(String code, {bool wifiOnly = true}) async {
    if (!supported) {
      throw const TranslationException(TranslationProblem.unsupported);
    }
    try {
      final done = await _manager.downloadModel(code, isWifiRequired: wifiOnly);
      if (!done) {
        throw const TranslationException(TranslationProblem.downloadFailed);
      }
    } on TranslationException {
      rethrow;
    } catch (_) {
      throw const TranslationException(TranslationProblem.downloadFailed);
    }
  }

  @override
  Future<void> deletePack(String code) async {
    if (!supported || code == builtInLanguage) return;
    await _manager.deleteModel(code);
    await _translators.remove(code)?.close();
  }

  @override
  Future<String?> detectLanguage(String text) async {
    if (!supported || text.trim().isEmpty) return null;
    try {
      final identifier = _identifier ??= LanguageIdentifier(
        confidenceThreshold: .5,
      );
      final tag = await identifier.identifyLanguage(text);
      if (tag == 'und') return null;
      // ML Kit answers with tags such as `zh-Latn` or `ja-Latn` for romanised text.
      final base = tag.split('-').first;
      return languageByCode(base)?.code;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<TranslationResult> translate(
    String text, {
    required String to,
    String? from,
  }) async {
    if (!supported) {
      throw const TranslationException(TranslationProblem.unsupported);
    }
    final source = from ?? await detectLanguage(text);
    if (source == null || source == to) {
      throw const TranslationException(TranslationProblem.nothingToTranslate);
    }
    if ((await missingPacks(source, to)).isNotEmpty) {
      throw const TranslationException(TranslationProblem.packMissing);
    }
    final src = TranslateLanguage.values.where((l) => l.bcpCode == source);
    final dst = TranslateLanguage.values.where((l) => l.bcpCode == to);
    if (src.isEmpty || dst.isEmpty) {
      throw const TranslationException(TranslationProblem.unsupported);
    }
    final key = '$source>$to';
    final translator = _translators[key] ??= OnDeviceTranslator(
      sourceLanguage: src.first,
      targetLanguage: dst.first,
    );
    try {
      final out = await translator.translateText(text);
      return TranslationResult(out, from: source, to: to);
    } catch (_) {
      throw const TranslationException(TranslationProblem.failed);
    }
  }

  @override
  Future<void> dispose() async {
    // Closing is best effort: a phone without the plugin (a widget test) must not fail a screen that is leaving.
    for (final t in _translators.values) {
      try {
        await t.close();
      } catch (_) {}
    }
    _translators.clear();
    try {
      await _identifier?.close();
    } catch (_) {}
    _identifier = null;
  }
}
