import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/translate/translation_service.dart';
import '../../core/user_error.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/press_scale.dart';
import '../../shared/widgets.dart';
import '../chat_av_providers.dart' show translationServiceProvider;

/// What a [TranslateScope] hands its builder: the text to show (the original or its translation) and the
/// button to put somewhere, which is null while translating is not possible for this text.
typedef TranslateBuilder = Widget Function(
  BuildContext context,
  String shown,
  Widget? button,
);

/// Translation for one piece of text a person reads (a post, a comment, a story), on the phone with
/// [TranslationService]: nothing is sent anywhere. The button is hidden when the phone cannot translate, when
/// its language has no model, or when the text is already in the reader's language. Tapping it shows the
/// translation in place, and "Show original" brings the first text back.
class TranslateScope extends ConsumerStatefulWidget {
  final String text;

  /// Makes the button's key unique in a list (`translate-<id>`, `show-original-<id>`).
  final String id;
  final TranslateBuilder builder;

  /// Light button text on a dark picture.
  final bool onDark;
  const TranslateScope({
    super.key,
    required this.text,
    required this.id,
    required this.builder,
    this.onDark = false,
  });

  @override
  ConsumerState<TranslateScope> createState() => _TranslateScopeState();
}

class _TranslateScopeState extends ConsumerState<TranslateScope> {
  bool? available;
  bool busy = false;
  TranslationResult? result;
  bool showing = false;
  String? _target;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final target = translationCodeForLocale(Localizations.localeOf(context));
    if (target != _target || available == null) {
      _target = target;
      _check();
    }
  }

  @override
  void didUpdateWidget(TranslateScope old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      result = null;
      showing = false;
      _check();
    }
  }

  Future<void> _check() async {
    final target = _target;
    final text = widget.text;
    if (target == null || text.trim().isEmpty) {
      if (mounted) setState(() => available = false);
      return;
    }
    try {
      final service = ref.read(translationServiceProvider);
      if (!service.supported) {
        if (mounted) setState(() => available = false);
        return;
      }
      final from = await service.detectLanguage(text);
      if (!mounted || text != widget.text) return;
      setState(() => available = from != null && from != target);
    } catch (_) {
      if (mounted) setState(() => available = false);
    }
  }

  Future<void> translate() async {
    final target = _target;
    if (target == null || busy) return;
    if (result != null) {
      setState(() => showing = true);
      return;
    }
    setState(() => busy = true);
    final service = ref.read(translationServiceProvider);
    try {
      var out = await _run(service, target);
      out ??= await _offerPack(service, target);
      if (mounted && out != null) {
        setState(() {
          result = out;
          showing = true;
        });
      }
    } on TranslationException catch (e) {
      if (!mounted) return;
      if (e.problem == TranslationProblem.nothingToTranslate ||
          e.problem == TranslationProblem.unsupported) {
        setState(() => available = false);
      } else {
        showMessage(context, 'Couldn’t translate that. Try again.');
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// The translation, or null when a language pack is missing.
  Future<TranslationResult?> _run(
    TranslationService service,
    String target,
  ) async {
    try {
      return await service.translate(widget.text, to: target);
    } on TranslationException catch (e) {
      if (e.problem == TranslationProblem.packMissing) return null;
      rethrow;
    }
  }

  /// Asks before downloading the missing language, then translates.
  Future<TranslationResult?> _offerPack(
    TranslationService service,
    String target,
  ) async {
    final from = await service.detectLanguage(widget.text);
    if (from == null || !mounted) return null;
    final missing = await service.missingPacks(from, target);
    if (!mounted) return null;
    final names = [
      for (final code in missing) languageByCode(code)?.english ?? code,
    ];
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Download a language?'),
        content: Text(
          'To translate on your phone, Hiyall needs ${names.join(' and ')} '
          '(about $languagePackMegabytes MB each, one time). The text you translate never leaves your phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            key: const Key('translate-download'),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (go != true) return null;
    try {
      for (final code in missing) {
        await service.downloadPack(code);
      }
    } on TranslationException {
      if (mounted) {
        showMessage(
          context,
          'Couldn’t download that language. Check your connection and try again.',
        );
      }
      return null;
    }
    return service.translate(widget.text, to: target, from: from);
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final color = widget.onDark ? Colors.white : t.accent;
    final shown = showing && result != null ? result!.text : widget.text;
    Widget? button;
    if (available == true || result != null) {
      final label = showing ? 'Show original' : 'Translate';
      button = PressScale(
        key: Key(
          showing ? 'show-original-${widget.id}' : 'translate-${widget.id}',
        ),
        minHeight: 48,
        semanticLabel: busy ? 'Translating' : label,
        onTap: busy
            ? null
            : showing
            ? () => setState(() => showing = false)
            : translate,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                else
                  Icon(Icons.translate_rounded, size: 16, color: color),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    busy ? 'Translating…' : label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return widget.builder(context, shown, button);
  }
}
