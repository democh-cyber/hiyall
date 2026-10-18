import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/chat/chat_engine.dart';
import '../core/chat/chat_prefs.dart';
import '../core/translate/translation_service.dart';
import '../shared/chat_tokens.dart';
import 'chat.dart' show chatEngineProvider;
import 'chat_av_providers.dart';

// Translating a message and the language settings. Everything runs on the phone: the text of a chat is handed
// to a local model and never to a server (docs/security/13-encrypted-chat-implementation.md, "On-device
// translation and reading aloud").

/// The language messages are translated into: the person's choice, else the phone's own language when a model
/// exists for it, else English.
String translationTarget(ChatPrefsData prefs) =>
    prefs.translateTo ??
    translationCodeForLocale(PlatformDispatcher.instance.locale) ??
    builtInLanguage;

String languageName(String code) => languageByCode(code)?.english ?? code;

/// One line of translation under a message: the translated text, which language it came from, and how to hide
/// it. [pending] shows a quiet "Translating…" instead; [failed] says it could not.
class TranslationLine extends StatelessWidget {
  final String? text, from;
  final bool pending, failed;
  final Color ink;
  final VoidCallback? onHide;
  const TranslationLine({
    super.key,
    required this.ink,
    this.text,
    this.from,
    this.pending = false,
    this.failed = false,
    this.onHide,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: ink.withValues(alpha: .92),
      fontSize: 14.5,
      height: 1.35,
    );
    return Padding(
      key: const Key('translation-line'),
      padding: const EdgeInsets.only(top: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: ink.withValues(alpha: .25))),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Semantics(
            container: true,
            label: pending
                ? 'Translating'
                : failed
                ? 'Couldn’t translate'
                : 'Translation${from == null ? '' : ' from ${languageName(from!)}'}: $text',
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (pending)
                    Text(
                      'Translating…',
                      style: style.copyWith(fontStyle: FontStyle.italic),
                    )
                  else if (failed)
                    Text('Couldn’t translate this message.', style: style)
                  else ...[
                    Text(
                      text ?? '',
                      key: const Key('translation-text'),
                      style: style,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      from == null
                          ? 'Translated on your phone'
                          : 'Translated from ${languageName(from!)} on your phone',
                      style: TextStyle(
                        color: ink.withValues(alpha: .65),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ the consent

/// Explains the language pack download and, when the person agrees, downloads [codes] (those not on the phone
/// yet). Returns true when every pack is there at the end. Nothing is downloaded without this sheet's button.
Future<bool> ensureTranslationPacks(
  BuildContext context,
  WidgetRef ref,
  ChatEngine engine,
  List<String> codes,
) async {
  final service = ref.read(translationServiceProvider);
  final missing = <String>[
    for (final c in codes)
      if (!await service.isInstalled(c)) c,
  ];
  if (missing.isEmpty) return true;
  if (!context.mounted) return false;
  final done = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) =>
        PackDownloadSheet(service: service, codes: missing, engine: engine),
  );
  return done ?? false;
}

class PackDownloadSheet extends StatefulWidget {
  final TranslationService service;
  final List<String> codes;
  final ChatEngine engine;
  const PackDownloadSheet({
    super.key,
    required this.service,
    required this.codes,
    required this.engine,
  });
  @override
  State<PackDownloadSheet> createState() => _PackDownloadSheetState();
}

class _PackDownloadSheetState extends State<PackDownloadSheet> {
  bool wifiOnly = true, busy = false, failed = false;
  String? current;

  Future<void> _download() async {
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      for (final code in widget.codes) {
        if (!mounted) return;
        setState(() => current = code);
        await widget.service.downloadPack(code, wifiOnly: wifiOnly);
      }
      await widget.engine.prefs.acceptTranslateConsent();
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final names = widget.codes.map(languageName).join(' and ');
    final size = widget.codes.length * languagePackMegabytes;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          key: const Key('translate-consent'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.translate_rounded, color: t.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Translate on your phone',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: t.text,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Hiyall translates messages with a model that runs on your phone. The words of your chats never leave it: no server and nobody else sees them. '
              'It needs a one-time download of the $names language ${widget.codes.length == 1 ? 'pack' : 'packs'}, about $size MB. '
              'You can remove packs any time in Settings, Chat language.',
              key: const Key('translate-consent-body'),
              style: TextStyle(
                fontSize: 15,
                height: 1.4,
                color: t.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('translate-wifi'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Download only on Wi-Fi',
                style: TextStyle(color: t.text),
              ),
              value: wifiOnly,
              onChanged: busy ? null : (v) => setState(() => wifiOnly = v),
            ),
            if (busy)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  key: const Key('translate-downloading'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Downloading ${languageName(current ?? widget.codes.first)}…',
                      style: TextStyle(color: t.text),
                    ),
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(),
                  ],
                ),
              ),
            if (failed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  wifiOnly
                      ? 'Couldn’t download. Connect to Wi-Fi, or turn the Wi-Fi switch off, and try again.'
                      : 'Couldn’t download. Check your connection and try again.',
                  key: const Key('translate-failed'),
                  style: TextStyle(color: t.error, fontSize: 14),
                ),
              ),
            const SizedBox(height: 4),
            FilledButton(
              key: const Key('translate-download'),
              onPressed: busy ? null : _download,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(ChatMetrics.hit),
              ),
              child: Text(failed ? 'Try again' : 'Download $size MB'),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const Key('translate-not-now'),
              onPressed: busy ? null : () => Navigator.of(context).pop(false),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(ChatMetrics.hit),
              ),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ the settings

/// Settings, Chat language: which language messages are translated into, and the language packs on the phone.
class ChatLanguageSettingsGroup extends ConsumerWidget {
  const ChatLanguageSettingsGroup({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.only(top: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
          child: Text(
            'CHAT LANGUAGE',
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            key: const Key('settings-chat-language'),
            leading: const Icon(Icons.translate_rounded),
            title: const Text(
              'Translation',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text(
              'Pick the language messages are translated into, and manage the packs on your phone',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ChatLanguageScreen(),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class ChatLanguageScreen extends ConsumerStatefulWidget {
  const ChatLanguageScreen({super.key});
  @override
  ConsumerState<ChatLanguageScreen> createState() => _ChatLanguageScreenState();
}

class _ChatLanguageScreenState extends ConsumerState<ChatLanguageScreen> {
  Set<String>? installed;
  ChatPrefsData prefs = const ChatPrefsData();
  String? busyCode;
  String? message;
  bool _ready = false;

  ChatEngine? get engine => ref.read(chatEngineProvider).asData?.value;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final service = ref.read(translationServiceProvider);
    final packs = await service.installedPacks();
    final e = engine;
    final p = e == null ? const ChatPrefsData() : await e.prefs.read();
    if (!mounted) return;
    setState(() {
      installed = packs;
      prefs = p;
      _ready = true;
    });
  }

  Future<void> _pickTarget() async {
    final e = engine;
    if (e == null) return;
    final code = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => LanguagePicker(
        current: translationTarget(prefs),
        installed: installed ?? const {},
        title: 'Translate messages into',
      ),
    );
    if (code == null || !mounted) return;
    await e.prefs.setTranslateTo(code);
    if (!mounted) return;
    setState(() => prefs = prefs.copyWith(translateTo: code));
    final service = ref.read(translationServiceProvider);
    if (service.supported && !await service.isInstalled(code)) {
      if (!mounted) return;
      await ensureTranslationPacks(context, ref, e, [code]);
      await _load();
    }
  }

  Future<void> _delete(String code) async {
    setState(() => busyCode = code);
    try {
      await ref.read(translationServiceProvider).deletePack(code);
      await _load();
      if (mounted) setState(() => message = '${languageName(code)} removed.');
    } finally {
      if (mounted) setState(() => busyCode = null);
    }
  }

  Future<void> _download(String code) async {
    final e = engine;
    if (e == null) return;
    await ensureTranslationPacks(context, ref, e, [code]);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final service = ref.watch(translationServiceProvider);
    final target = translationTarget(prefs);
    final packs = [
      for (final l in translationLanguages)
        if (l.code != builtInLanguage &&
            (installed ?? const <String>{}).contains(l.code))
          l,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Chat language')),
      body: ListView(
        key: const Key('chat-language-screen'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'Messages are translated on your phone. The text of your chats never goes to a server or anyone else.',
            style: TextStyle(color: t.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 16),
          if (!service.supported)
            Text(
              'Translation works in the Android and iOS apps.',
              key: const Key('translate-unsupported'),
              style: TextStyle(color: t.textSecondary),
            ),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              key: const Key('translate-to'),
              minTileHeight: ChatMetrics.hit,
              leading: const Icon(Icons.language_rounded),
              title: const Text(
                'Translate to',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                prefs.translateTo == null
                    ? '${languageName(target)} (your phone’s language)'
                    : languageName(target),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _ready && engine != null ? _pickTarget : null,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'LANGUAGE PACKS ON THIS PHONE',
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w800,
              color: t.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          if (!_ready)
            const LinearProgressIndicator()
          else if (packs.isEmpty)
            Text(
              'None yet. English is built in. A pack of about $languagePackMegabytes MB is downloaded the first time you translate from or into another language.',
              key: const Key('translate-no-packs'),
              style: TextStyle(color: t.textSecondary, height: 1.4),
            )
          else
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final l in packs)
                    ListTile(
                      key: Key('pack-${l.code}'),
                      minTileHeight: ChatMetrics.hit,
                      title: Text(l.english),
                      subtitle: Text(
                        '${l.native} · about $languagePackMegabytes MB',
                      ),
                      trailing: busyCode == l.code
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              key: Key('pack-delete-${l.code}'),
                              tooltip: 'Remove ${l.english}',
                              icon: const Icon(Icons.delete_outline_rounded),
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              onPressed: () => unawaited(_delete(l.code)),
                            ),
                    ),
                ],
              ),
            ),
          if (_ready &&
              service.supported &&
              !(installed ?? const {}).contains(target))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton.icon(
                key: const Key('pack-download-target'),
                onPressed: () => unawaited(_download(target)),
                icon: const Icon(Icons.download_rounded),
                label: Text('Download ${languageName(target)}'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(ChatMetrics.hit),
                ),
              ),
            ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                message!,
                key: const Key('translate-message'),
                style: TextStyle(color: t.textSecondary),
              ),
            ),
          const SizedBox(height: 24),
          Text(
            'Auto-translate is a switch inside each chat (the chat’s menu). It is kept only on this phone.',
            style: TextStyle(color: t.textSecondary, height: 1.4, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// A searchable list of the translation languages. Pops the chosen code.
class LanguagePicker extends StatefulWidget {
  final String current, title;
  final Set<String> installed;
  const LanguagePicker({
    super.key,
    required this.current,
    required this.installed,
    required this.title,
  });
  @override
  State<LanguagePicker> createState() => _LanguagePickerState();
}

class _LanguagePickerState extends State<LanguagePicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final q = query.trim().toLowerCase();
    final shown = [
      for (final l in translationLanguages)
        if (q.isEmpty ||
            l.english.toLowerCase().contains(q) ||
            l.native.toLowerCase().contains(q))
          l,
    ];
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: t.text,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: const Key('language-search'),
                onChanged: (v) => setState(() => query = v),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: 'Search languages',
                ),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final l in shown)
                    ListTile(
                      key: Key('language-${l.code}'),
                      minTileHeight: ChatMetrics.hit,
                      title: Text(l.english),
                      subtitle: Text(l.native),
                      trailing: l.code == widget.current
                          ? Icon(Icons.check_rounded, color: t.accent)
                          : (l.code == builtInLanguage ||
                                widget.installed.contains(l.code))
                          ? Text(
                              'On this phone',
                              style: TextStyle(
                                color: t.textTertiary,
                                fontSize: 12,
                              ),
                            )
                          : null,
                      onTap: () => Navigator.of(context).pop(l.code),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
