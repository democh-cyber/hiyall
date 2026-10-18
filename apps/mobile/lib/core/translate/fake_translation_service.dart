import 'translation_service.dart';

/// A deterministic stand-in for tests and previews: it "translates" by wrapping the text as `[to] text`, tells
/// the language of a text from a small table, needs the same packs the real service needs and records every
/// text it was given (so a test can prove what was, and was not, translated).
class FakeTranslationService extends TranslationService {
  FakeTranslationService({
    Set<String> installed = const {},
    this.isSupported = true,
    Map<String, String> detects = const {},
  }) : _installed = {builtInLanguage, ...installed},
       detects = {...detects};

  final Set<String> _installed;
  final bool isSupported;

  /// Text to detected language code; anything else is detected as English.
  final Map<String, String> detects;
  final translated = <String>[];
  final downloads = <String>[];
  final deletions = <String>[];
  bool failDownloads = false, failTranslation = false;

  /// Completes a pending download when set (lets a test watch the "downloading" state).
  Future<void>? downloadGate;

  @override
  bool get supported => isSupported;

  @override
  Future<Set<String>> installedPacks() async => {..._installed};

  @override
  Future<void> downloadPack(String code, {bool wifiOnly = true}) async {
    downloads.add(code);
    await downloadGate;
    if (failDownloads) {
      throw const TranslationException(TranslationProblem.downloadFailed);
    }
    _installed.add(code);
  }

  @override
  Future<void> deletePack(String code) async {
    if (code == builtInLanguage) return;
    deletions.add(code);
    _installed.remove(code);
  }

  @override
  Future<String?> detectLanguage(String text) async =>
      text.trim().isEmpty ? null : (detects[text] ?? 'en');

  @override
  Future<TranslationResult> translate(
    String text, {
    required String to,
    String? from,
  }) async {
    if (!isSupported) {
      throw const TranslationException(TranslationProblem.unsupported);
    }
    final source = from ?? await detectLanguage(text);
    if (source == null || source == to) {
      throw const TranslationException(TranslationProblem.nothingToTranslate);
    }
    if ((await missingPacks(source, to)).isNotEmpty) {
      throw const TranslationException(TranslationProblem.packMissing);
    }
    if (failTranslation) {
      throw const TranslationException(TranslationProblem.failed);
    }
    translated.add(text);
    return TranslationResult('[$to] $text', from: source, to: to);
  }
}
