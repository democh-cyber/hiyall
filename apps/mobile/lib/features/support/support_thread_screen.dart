import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart' show ApiFailure;
import '../../core/support.dart';
import '../../core/user_error.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/widgets.dart';
import '../settings.dart' show timeAgo;
import 'support_widgets.dart';

/// One conversation with the Hiyall team: bubbles, a box to write in, and a closed state.
class SupportThreadScreen extends ConsumerStatefulWidget {
  final String threadId;

  /// Words to put in the box (a message that was refused because a conversation already existed).
  final String? draft;
  const SupportThreadScreen(this.threadId, {super.key, this.draft});
  @override
  ConsumerState<SupportThreadScreen> createState() =>
      _SupportThreadScreenState();
}

class _SupportThreadScreenState extends ConsumerState<SupportThreadScreen> {
  /// A quiet re-read while the screen is open, for the time the socket is not live.
  static const pollEvery = Duration(seconds: 30);

  late final text = TextEditingController(text: widget.draft);
  final scroll = ScrollController();
  Timer? poll;

  /// The server's words for the last refused send, above the box.
  String? problem;

  @override
  void initState() {
    super.initState();
    text.addListener(() => setState(() {}));
    poll = Timer.periodic(pollEvery, (_) => reread());
  }

  @override
  void dispose() {
    poll?.cancel();
    text.dispose();
    scroll.dispose();
    super.dispose();
  }

  void reread() =>
      ref.read(supportConversationProvider(widget.threadId).notifier).refresh();

  void toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  Future<void> send() async {
    final body = text.text.trim();
    if (body.isEmpty) return;
    setState(() => problem = null);
    try {
      await ref
          .read(supportConversationProvider(widget.threadId).notifier)
          .send(body);
      text.clear();
    } catch (error) {
      if (!mounted) return;
      final closed =
          error is ApiFailure && error.code == 'SUPPORT_THREAD_CLOSED';
      // The closed state replaces the box; the words stay for the next message.
      if (!closed) setState(() => problem = friendlyError(error));
      if (closed) showFailure(context, error);
    }
  }

  Future<void> close() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close this conversation?'),
        content: const Text(
          'You can start a new message any time. The team can still reopen it if they need to reply.',
        ),
        actions: [
          TextButton(
            key: const Key('support-close-keep'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep open'),
          ),
          FilledButton(
            key: const Key('support-close-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Close it'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref
          .read(supportConversationProvider(widget.threadId).notifier)
          .close();
    } catch (error) {
      if (mounted) showFailure(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.threadId;
    final conversation = ref.watch(supportConversationProvider(id));
    final value = conversation.asData?.value;
    ref.listen(supportSignalProvider, (_, _) => reread());
    ref.listen(supportConversationProvider(id), (before, after) {
      final was = before?.asData?.value.messages.length ?? 0;
      final now = after.asData?.value.messages.length ?? 0;
      if (now != was) toEnd();
    });
    final category = value?.thread.category;
    return ReadingWidth(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: () => context.canPop()
                          ? context.pop()
                          : context.go('/profile/support'),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Message support'),
                    ),
                  ),
                ),
                if (value != null && value.thread.open)
                  PopupMenuButton<String>(
                    key: const Key('support-menu'),
                    tooltip: 'More',
                    constraints: const BoxConstraints(minWidth: 48),
                    onSelected: (_) => close(),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'close',
                        key: Key('support-close'),
                        child: Text('Close conversation'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Semantics(
                header: true,
                child: Text(
                  category == null
                      ? 'Support'
                      : 'Support: ${SupportCategoryStyle.of(category).label}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
          ),
          Expanded(
            child: value == null
                ? Center(
                    child: conversation.isLoading
                        ? const CircularProgressIndicator()
                        : Padding(
                            padding: const EdgeInsets.all(20),
                            child: FailureCard(
                              key: const Key('support-thread-error'),
                              error: conversation.error!,
                              retry: () => ref.invalidate(
                                supportConversationProvider(id),
                              ),
                            ),
                          ),
                  )
                : ListView.builder(
                    key: const Key('support-messages'),
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    itemCount: value.messages.length,
                    itemBuilder: (context, i) => SupportBubble(
                      value.messages[i],
                      startsRun:
                          i == 0 ||
                          value.messages[i - 1].mine != value.messages[i].mine,
                    ),
                  ),
          ),
          if (value != null)
            value.thread.open
                ? _Composer(
                    controller: text,
                    sending: value.sending,
                    problem: problem,
                    onSend: send,
                  )
                : _ClosedBar(thread: value.thread),
        ],
      ),
    );
  }
}

class SupportBubble extends StatelessWidget {
  final SupportMessage message;
  final bool startsRun;
  const SupportBubble(this.message, {super.key, this.startsRun = true});

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final mine = message.mine;
    final ink = mine ? tokens.outgoingInk : tokens.incomingInk;
    final meta = mine ? tokens.outgoingMeta : tokens.incomingMeta;
    return Padding(
      padding: EdgeInsets.only(top: startsRun ? ChatMetrics.runGap : 4),
      child: Align(
        alignment: mine
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * .82,
          ),
          child: Semantics(
            container: true,
            label: '${mine ? 'You' : 'Hiyall team'}: ${message.body}',
            child: ExcludeSemantics(
              child: Container(
                key: Key('support-message-${message.id}'),
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                decoration: BoxDecoration(
                  color: mine ? null : tokens.incoming,
                  gradient: mine
                      ? LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: tokens.outgoing,
                        )
                      : null,
                  border: mine || tokens.incomingBorder.a == 0
                      ? null
                      : Border.all(color: tokens.incomingBorder),
                  borderRadius: BorderRadiusDirectional.only(
                    topStart: const Radius.circular(ChatMetrics.bubbleRadius),
                    topEnd: const Radius.circular(ChatMetrics.bubbleRadius),
                    bottomStart: Radius.circular(
                      mine ? ChatMetrics.bubbleRadius : ChatMetrics.bubbleTail,
                    ),
                    bottomEnd: Radius.circular(
                      mine ? ChatMetrics.bubbleTail : ChatMetrics.bubbleRadius,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!mine)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          'Hiyall team',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: meta,
                          ),
                        ),
                      ),
                    Text(
                      message.body,
                      style: TextStyle(color: ink, height: 1.4, fontSize: 15.5),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      timeAgo(message.createdAt),
                      style: TextStyle(fontSize: 11.5, color: meta),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final String? problem;
  final VoidCallback onSend;
  const _Composer({
    required this.controller,
    required this.sending,
    required this.problem,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final canSend = !sending && controller.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: tokens.bg2,
        border: Border(top: BorderSide(color: tokens.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Not end-to-end encrypted. Our team can read this.',
              key: const Key('support-thread-note'),
              style: TextStyle(fontSize: 12.5, color: tokens.textSecondary),
            ),
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    problem!,
                    key: const Key('support-send-error'),
                    style: TextStyle(color: tokens.error, height: 1.35),
                  ),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('support-reply'),
                    controller: controller,
                    minLines: 1,
                    maxLines: 5,
                    maxLength: supportBodyMax,
                    textCapitalization: TextCapitalization.sentences,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration(
                      hintText: 'Write a message',
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('support-reply-send'),
                  tooltip: 'Send',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: canSend ? onSend : null,
                  icon: sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ClosedBar extends StatelessWidget {
  final SupportThread thread;
  const _ClosedBar({required this.thread});

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    return Container(
      key: const Key('support-closed'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: tokens.bg2,
        border: Border(top: BorderSide(color: tokens.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                'This conversation is closed',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: tokens.text,
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              key: const Key('support-start-new'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: () => context.pushReplacement(
                '/profile/support/new?category=${thread.category.name}',
              ),
              child: const Text('Start a new message'),
            ),
          ],
        ),
      ),
    );
  }
}
