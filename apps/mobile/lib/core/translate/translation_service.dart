import 'dart:ui' show Locale;

/// On-device translation, shared by the chat and anything else that wants to translate text a person reads
/// (stories and comments can reuse it). Everything behind this interface runs on the phone: the text never
/// leaves it, no server and no third party sees it. The only network traffic is the one-time download of a
/// language pack, which carries no text.
///
/// The interface exists so tests (and previews) run without the platform plugin: see
/// `FakeTranslationService`.

/// A language the phone can translate from and into, by its BCP 47 code, with its name in English and in
/// itself.
class TranslationLanguage {
  final String code, english, native;
  const TranslationLanguage(this.code, this.english, this.native);
  @override
  String toString() => 'TranslationLanguage($code)';
}

/// The languages the on-device models cover. English is built in; every other language is a pack of roughly
/// 30 MB that is downloaded once and can be deleted again.
const translationLanguages = <TranslationLanguage>[
  TranslationLanguage('af', 'Afrikaans', 'Afrikaans'),
  TranslationLanguage('sq', 'Albanian', 'Shqip'),
  TranslationLanguage('ar', 'Arabic', 'العربية'),
  TranslationLanguage('be', 'Belarusian', 'Беларуская'),
  TranslationLanguage('bn', 'Bengali', 'বাংলা'),
  TranslationLanguage('bg', 'Bulgarian', 'Български'),
  TranslationLanguage('ca', 'Catalan', 'Català'),
  TranslationLanguage('zh', 'Chinese', '中文'),
  TranslationLanguage('hr', 'Croatian', 'Hrvatski'),
  TranslationLanguage('cs', 'Czech', 'Čeština'),
  TranslationLanguage('da', 'Danish', 'Dansk'),
  TranslationLanguage('nl', 'Dutch', 'Nederlands'),
  TranslationLanguage('en', 'English', 'English'),
  TranslationLanguage('eo', 'Esperanto', 'Esperanto'),
  TranslationLanguage('et', 'Estonian', 'Eesti'),
  TranslationLanguage('fi', 'Finnish', 'Suomi'),
  TranslationLanguage('fr', 'French', 'Français'),
  TranslationLanguage('gl', 'Galician', 'Galego'),
  TranslationLanguage('ka', 'Georgian', 'ქართული'),
  TranslationLanguage('de', 'German', 'Deutsch'),
  TranslationLanguage('el', 'Greek', 'Ελληνικά'),
  TranslationLanguage('gu', 'Gujarati', 'ગુજરાતી'),
  TranslationLanguage('ht', 'Haitian Creole', 'Kreyòl ayisyen'),
  TranslationLanguage('he', 'Hebrew', 'עברית'),
  TranslationLanguage('hi', 'Hindi', 'हिन्दी'),
  TranslationLanguage('hu', 'Hungarian', 'Magyar'),
  TranslationLanguage('is', 'Icelandic', 'Íslenska'),
  TranslationLanguage('id', 'Indonesian', 'Bahasa Indonesia'),
  TranslationLanguage('ga', 'Irish', 'Gaeilge'),
  TranslationLanguage('it', 'Italian', 'Italiano'),
  TranslationLanguage('ja', 'Japanese', '日本語'),
  TranslationLanguage('kn', 'Kannada', 'ಕನ್ನಡ'),
  TranslationLanguage('ko', 'Korean', '한국어'),
  TranslationLanguage('lv', 'Latvian', 'Latviešu'),
  TranslationLanguage('lt', 'Lithuanian', 'Lietuvių'),
  TranslationLanguage('mk', 'Macedonian', 'Македонски'),
  TranslationLanguage('ms', 'Malay', 'Bahasa Melayu'),
  TranslationLanguage('mt', 'Maltese', 'Malti'),
  TranslationLanguage('mr', 'Marathi', 'मराठी'),
  TranslationLanguage('no', 'Norwegian', 'Norsk'),
  TranslationLanguage('fa', 'Persian', 'فارسی'),
  TranslationLanguage('pl', 'Polish', 'Polski'),
  TranslationLanguage('pt', 'Portuguese', 'Português'),
  TranslationLanguage('ro', 'Romanian', 'Română'),
  TranslationLanguage('ru', 'Russian', 'Русский'),
  TranslationLanguage('sk', 'Slovak', 'Slovenčina'),
  TranslationLanguage('sl', 'Slovenian', 'Slovenščina'),
  TranslationLanguage('es', 'Spanish', 'Español'),
  TranslationLanguage('sw', 'Swahili', 'Kiswahili'),
  TranslationLanguage('sv', 'Swedish', 'Svenska'),
  TranslationLanguage('tl', 'Tagalog', 'Tagalog'),
  TranslationLanguage('ta', 'Tamil', 'தமிழ்'),
  TranslationLanguage('te', 'Telugu', 'తెలుగు'),
  TranslationLanguage('th', 'Thai', 'ไทย'),
  TranslationLanguage('tr', 'Turkish', 'Türkçe'),
  TranslationLanguage('uk', 'Ukrainian', 'Українська'),
  TranslationLanguage('ur', 'Urdu', 'اردو'),
  TranslationLanguage('vi', 'Vietnamese', 'Tiếng Việt'),
  TranslationLanguage('cy', 'Welsh', 'Cymraeg'),
];

/// English needs no download: the other models translate through it.
const builtInLanguage = 'en';

/// Roughly how big one language pack is, for the sentence that asks before downloading it.
const languagePackMegabytes = 30;

TranslationLanguage? languageByCode(String? code) {
  if (code == null) return null;
  for (final l in translationLanguages) {
    if (l.code == code) return l;
  }
  return null;
}

/// The translation language that stands for [locale] (`pt_BR` is Portuguese, `nb` is Norwegian), or null when
/// the phone's language has no on-device model.
String? translationCodeForLocale(Locale locale) {
  var code = locale.languageCode.toLowerCase();
  if (code == 'nb' || code == 'nn') code = 'no';
  if (code == 'fil') code = 'tl';
  if (code == 'iw') code = 'he';
  return languageByCode(code)?.code;
}

/// What a translation call can refuse for.
enum TranslationProblem {
  /// This phone cannot translate (a platform without the models).
  unsupported,

  /// A language pack the translation needs is not on the phone yet.
  packMissing,

  /// The text is already in the target language, or no language could be told.
  nothingToTranslate,

  /// The pack could not be downloaded (offline, no space).
  downloadFailed,

  /// Anything else.
  failed,
}

class TranslationException implements Exception {
  final TranslationProblem problem;
  const TranslationException(this.problem);
  @override
  String toString() => 'TranslationException(${problem.name})';
}

class TranslationResult {
  /// The translated text, and the language it was translated from and into.
  final String text, from, to;
  const TranslationResult(this.text, {required this.from, required this.to});
}

abstract class TranslationService {
  /// Whether this phone can translate at all (Android and iOS).
  bool get supported;

  /// Language packs on the phone. English is always there.
  Future<Set<String>> installedPacks();

  Future<bool> isInstalled(String code) async =>
      code == builtInLanguage || (await installedPacks()).contains(code);

  /// Downloads a pack (a one-time download of roughly [languagePackMegabytes] MB; no text is sent). With
  /// [wifiOnly] it waits for Wi-Fi. Throws [TranslationException] with [TranslationProblem.downloadFailed].
  Future<void> downloadPack(String code, {bool wifiOnly = true});

  /// Removes a pack from the phone.
  Future<void> deletePack(String code);

  /// The language of [text] as a translation language code, or null when it cannot be told or has no model.
  Future<String?> detectLanguage(String text);

  /// Translates [text] into [to] on the phone. [from] defaults to the detected language. Throws
  /// [TranslationException]: [TranslationProblem.packMissing] when a needed pack is not installed (nothing is
  /// downloaded by surprise), [TranslationProblem.nothingToTranslate] when the text is already in [to].
  Future<TranslationResult> translate(
    String text, {
    required String to,
    String? from,
  });

  /// Which packs a translation from [from] into [to] needs that are not on the phone yet.
  Future<List<String>> missingPacks(String from, String to) async {
    final out = <String>[];
    for (final code in {from, to}) {
      if (!await isInstalled(code)) out.add(code);
    }
    return out;
  }

  Future<void> dispose() async {}
}
