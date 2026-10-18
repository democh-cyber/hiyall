import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart' show ApiFailure;
import '../../core/support.dart';
import '../../core/user_error.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/press_scale.dart';
import '../../shared/widgets.dart';
import 'support_widgets.dart';

/// A new message to the team: a topic, the words, and a plain warning above the box that support
/// messages are not end-to-end encrypted.
class NewSupportThreadScreen extends ConsumerStatefulWidget {
  /// Pre-selects a topic (the closed conversation's "Start a new message").
  final SupportCategory? category;
  const NewSupportThreadScreen({super.key, this.category});
  @override
  ConsumerState<NewSupportThreadScreen> createState() =>
      _NewSupportThreadScreenState();
}

class _NewSupportThreadScreenState
    extends ConsumerState<NewSupportThreadScreen> {
  final text = TextEditingController();
  SupportCategory? category;
  bool busy = false;

  /// The server's words for the last refusal, shown above the button.
  String? problem;

  @override
  void initState() {
    super.initState();
    category = widget.category;
    text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  bool get canSend => !busy && category != null && text.text.trim().isNotEmpty;

  Future<void> send() async {
    final chosen = category;
    final body = text.text.trim();
    if (chosen == null || body.isEmpty || busy) return;
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final threads = ref.read(supportThreadsProvider.notifier);
    setState(() {
      busy = true;
      problem = null;
    });
    try {
      final thread = await threads.create(chosen, body);
      ref.invalidate(supportUnreadProvider);
      if (!mounted) return;
      router.pushReplacement('/profile/support/${thread.id}');
    } on ApiFailure catch (error) {
      if (error.code == 'SUPPORT_THREAD_OPEN') {
        SupportThread? existing;
        try {
          existing = await threads.findOpen(chosen);
        } catch (_) {}
        if (!mounted) return;
        if (existing != null) {
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text(
                  'You already have an open conversation about this. Your message is ready to send there.',
                ),
              ),
            );
          router.pushReplacement(
            '/profile/support/${existing.id}',
            extra: body,
          );
          return;
        }
      }
      if (mounted) setState(() => problem = friendlyError(error));
    } catch (error) {
      if (mounted) setState(() => problem = friendlyError(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final safety = category == SupportCategory.safety;
    return ReadingWidth(
      child: ListView(
        key: const Key('support-new-form'),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => context.canPop()
                  ? context.pop()
                  : context.go('/profile/support'),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Message support'),
            ),
          ),
          Semantics(
            header: true,
            child: Text(
              'New message',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'What is it about?',
            style: TextStyle(fontWeight: FontWeight.w800, color: tokens.text),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in SupportCategory.values)
                _TopicChip(
                  c,
                  selected: category == c,
                  onTap: () => setState(() => category = c),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const SupportNote(
            supportEncryptionNote,
            key: Key('support-encryption-note'),
          ),
          if (safety) ...[
            const SizedBox(height: 10),
            const SupportNote(
              supportEmergencyNote,
              key: Key('support-emergency-note'),
              icon: Icons.emergency_outlined,
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            key: const Key('support-body'),
            controller: text,
            minLines: 5,
            maxLines: 10,
            maxLength: supportBodyMax,
            textCapitalization: TextCapitalization.sentences,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              labelText: 'Your message',
              alignLabelWithHint: true,
            ),
          ),
          if (problem != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                problem!,
                key: const Key('support-new-error'),
                style: TextStyle(color: tokens.error, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: 14),
          FilledButton(
            key: const Key('support-send'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: canSend ? send : null,
            child: Text(busy ? 'Sending…' : 'Send'),
          ),
        ],
      ),
    );
  }
}

class _TopicChip extends StatelessWidget {
  final SupportCategory category;
  final bool selected;
  final VoidCallback onTap;
  const _TopicChip(
    this.category, {
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final style = SupportCategoryStyle.of(category);
    final fg = selected ? tokens.onLime : tokens.text;
    return PressScale(
      key: Key('support-topic-${category.name}'),
      minHeight: 48,
      selected: selected,
      semanticLabel: style.label,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? tokens.lime : Colors.transparent,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: selected ? tokens.lime : tokens.hairline,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(style.icon, size: 18, color: fg),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                style.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w800, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
