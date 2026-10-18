import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/push/push_service.dart';
import 'package:hiyall/core/support.dart';

import 'support/app_host.dart';
import 'support/scripted_api.dart';

Map<String, dynamic> threadJson(
  String id, {
  String category = 'account',
  String status = 'open',
  bool unread = false,
  String lastAuthor = 'member',
  String preview = 'Help me',
}) => {
  'threadId': id,
  'category': category,
  'status': status,
  'createdAt': '2026-10-10T09:00:00Z',
  'lastMessageAt': '2026-10-10T10:00:00Z',
  'unread': unread,
  'lastAuthor': lastAuthor,
  'preview': preview,
};

Map<String, dynamic> messageJson(String id, String author, String body) => {
  'messageId': id,
  'author': author,
  'body': body,
  'createdAt': '2026-10-10T10:00:00Z',
};

class SupportServer {
  final threads = <Map<String, dynamic>>[];
  final messages = <String, List<Map<String, dynamic>>>{};
  final created = <Map<String, dynamic>>[];
  final sentMessages = <Map<String, dynamic>>[];
  Object? createFails, sendFails;
  int unread = 0;

  ScriptedApi install() {
    final api = ScriptedApi();
    api.on('GET /v1/support/unread', (_, _) => {'unreadCount': unread});
    api.on(
      'GET /v1/support/threads',
      (_, _) => {
        'items': threads,
        'nextCursor': null,
        'hasMore': false,
        'unreadCount': unread,
      },
    );
    api.on('POST /v1/support/threads', (body, _) {
      created.add(Map<String, dynamic>.from(body! as Map));
      final error = createFails;
      if (error != null) throw error;
      final t = threadJson(
        'new-1',
        category: (body as Map)['category'] as String,
        preview: body['body'] as String,
      );
      threads.insert(0, t);
      messages['new-1'] = [
        messageJson('m-1', 'member', body['body'] as String),
      ];
      return t;
    });
    return api;
  }

  /// Routes for one thread id (the path has the id in it).
  void thread(ScriptedApi api, String id) {
    api.on(
      'GET /v1/support/threads/$id',
      (_, _) => threads.firstWhere((t) => t['threadId'] == id),
    );
    api.on(
      'GET /v1/support/threads/$id/messages',
      (_, _) => {'items': messages[id] ?? [], 'nextCursor': null},
    );
    api.on('POST /v1/support/threads/$id/messages', (body, _) {
      sentMessages.add(Map<String, dynamic>.from(body! as Map));
      final error = sendFails;
      if (error != null) throw error;
      final m = messageJson(
        'm-${messages[id]!.length + 1}',
        'member',
        (body as Map)['body'] as String,
      );
      messages[id]!.add(m);
      return m;
    });
    api.on('POST /v1/support/threads/$id/close', (_, _) {
      threads.firstWhere((t) => t['threadId'] == id)['status'] = 'closed';
      return {'closed': true};
    });
  }
}

Finder get body => find.byKey(const Key('support-body'));

void main() {
  late SupportServer server;
  late ScriptedApi api;
  setUp(() {
    server = SupportServer();
    api = server.install();
    api.on(
      'GET /v1/notices/summary',
      (_, _) => {'unreadCount': 0, 'pinned': []},
    );
  });

  group('list', () {
    testWidgets('threads with topic, status, last words and an unread dot', (
      tester,
    ) async {
      server.threads.addAll([
        threadJson(
          't1',
          category: 'safety',
          unread: true,
          lastAuthor: 'staff',
          preview: 'We are looking into it',
        ),
        threadJson('t2', status: 'closed', preview: 'Thanks'),
      ]);
      await launchApp(tester, api, '/profile/support');
      expect(find.text('Message support'), findsWidgets);
      expect(find.text('Safety'), findsOneWidget);
      expect(find.text('Account'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Closed'), findsOneWidget);
      expect(find.text('Hiyall team: We are looking into it'), findsOneWidget);
      expect(find.text('You: Thanks'), findsOneWidget);
      expect(find.byKey(const Key('support-unread-t1')), findsOneWidget);
      expect(find.byKey(const Key('support-unread-t2')), findsNothing);
      expect(find.byKey(const Key('support-new')), findsOneWidget);
    });

    testWidgets('empty state and error state', (tester) async {
      await launchApp(tester, api, '/profile/support');
      expect(find.byKey(const Key('support-empty')), findsOneWidget);
    });

    testWidgets('error state offers a retry', (tester) async {
      api.routes.remove('GET /v1/support/threads');
      await launchApp(tester, api, '/profile/support');
      expect(find.byKey(const Key('support-error')), findsOneWidget);
    });

    testWidgets('Help & Safety shows a dot while the team has replied', (
      tester,
    ) async {
      server.unread = 1;
      final c = await launchApp(tester, api, '/profile/help');
      expect(find.text('The team replied'), findsOneWidget);
      await tester.tap(find.byKey(const Key('help-support')));
      await tester.pumpAndSettle();
      expect(where(c), '/profile/support');
    });

    testWidgets('no reply waiting: plain subtitle', (tester) async {
      await launchApp(tester, api, '/profile/help');
      expect(
        find.text('Write to the Hiyall team inside the app'),
        findsOneWidget,
      );
      expect(find.text('The team replied'), findsNothing);
    });
  });

  group('new message', () {
    testWidgets('the encryption note sits above the box, in plain words', (
      tester,
    ) async {
      await launchApp(tester, api, '/profile/support/new');
      final note = find.byKey(const Key('support-encryption-note'));
      expect(note, findsOneWidget);
      expect(
        find.text(
          'Messages to support are not end-to-end encrypted. Our team can read them. Don’t send passwords or ID numbers.',
        ),
        findsOneWidget,
      );
      expect(
        tester.getBottomLeft(note).dy,
        lessThan(tester.getTopLeft(body).dy),
      );
      expect(find.byKey(const Key('support-emergency-note')), findsNothing);
    });

    testWidgets('Send waits for a topic and words; the box counts to 2000', (
      tester,
    ) async {
      await launchApp(tester, api, '/profile/support/new');
      bool canSend() =>
          tester
              .widget<FilledButton>(find.byKey(const Key('support-send')))
              .onPressed !=
          null;
      expect(canSend(), isFalse);
      await tester.enterText(body, 'Hello');
      await tester.pump();
      expect(canSend(), isFalse, reason: 'no topic yet');
      expect(find.text('5/2000'), findsOneWidget);
      await tester.tap(find.byKey(const Key('support-topic-bug')));
      await tester.pump();
      expect(canSend(), isTrue);
      await tester.enterText(body, '   ');
      await tester.pump();
      expect(canSend(), isFalse);
      await tester.enterText(body, 'x' * 2100);
      await tester.pump();
      expect(find.text('2000/2000'), findsOneWidget);
    });

    testWidgets('Safety mentions emergency services', (tester) async {
      await launchApp(tester, api, '/profile/support/new');
      await tester.tap(find.byKey(const Key('support-topic-safety')));
      await tester.pump();
      expect(find.byKey(const Key('support-emergency-note')), findsOneWidget);
      expect(find.textContaining('emergency services'), findsOneWidget);
    });

    testWidgets('creates the conversation and opens it', (tester) async {
      final c = await launchApp(tester, api, '/profile/support/new');
      server.thread(api, 'new-1');
      await tester.tap(find.byKey(const Key('support-topic-account')));
      await tester.enterText(body, '  I cannot log in  ');
      await tester.pump();
      await tester.tap(find.byKey(const Key('support-send')));
      await tester.pumpAndSettle();
      expect(server.created.single, {
        'category': 'account',
        'body': 'I cannot log in',
      });
      expect(where(c), '/profile/support/new-1');
      expect(find.text('I cannot log in'), findsOneWidget);
      expect(find.text('Support: Account'), findsOneWidget);
    });

    testWidgets(
      '409 SUPPORT_THREAD_OPEN opens the existing conversation with the text',
      (tester) async {
        server.threads.add(
          threadJson('t7', category: 'bug', preview: 'Earlier'),
        );
        server.messages['t7'] = [messageJson('m-0', 'member', 'Earlier')];
        server.thread(api, 't7');
        server.createFails = const ApiFailure(
          'You already have an open conversation about this.',
          409,
          'SUPPORT_THREAD_OPEN',
        );
        final c = await launchApp(tester, api, '/profile/support/new');
        await tester.tap(find.byKey(const Key('support-topic-bug')));
        await tester.enterText(body, 'It crashes again');
        await tester.pump();
        await tester.tap(find.byKey(const Key('support-send')));
        await tester.pumpAndSettle();
        expect(where(c), '/profile/support/t7');
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('support-reply')))
              .controller!
              .text,
          'It crashes again',
        );
        expect(
          find.textContaining('already have an open conversation'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '429 DAILY_LIMIT and 422 show the server’s words and keep the text',
      (tester) async {
        await launchApp(tester, api, '/profile/support/new');
        await tester.tap(find.byKey(const Key('support-topic-other')));
        await tester.enterText(body, 'Hi');
        await tester.pump();
        server.createFails = const ApiFailure(
          'You’ve reached today’s limit for messages to support. Try again tomorrow.',
          429,
          'DAILY_LIMIT',
        );
        await tester.tap(find.byKey(const Key('support-send')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('support-new-error')), findsOneWidget);
        expect(find.textContaining('today’s limit'), findsOneWidget);
        expect(tester.widget<TextField>(body).controller!.text, 'Hi');

        server.createFails = const ApiFailure(
          'That message can’t be sent as written.',
          422,
          'VALIDATION',
        );
        // The error line pushed the button down: scroll to it.
        await tester.scrollUntilVisible(
          find.byKey(const Key('support-send')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.byKey(const Key('support-send')));
        await tester.pumpAndSettle();
        expect(find.textContaining('can’t be sent as written'), findsOneWidget);
      },
    );
  });

  group('conversation', () {
    setUp(() {
      server.threads.add(threadJson('t1', lastAuthor: 'staff', unread: true));
      server.messages['t1'] = [
        messageJson('m1', 'member', 'My account is locked'),
        messageJson('m2', 'staff', 'Try resetting your password'),
      ];
      server.thread(api, 't1');
    });

    testWidgets('bubbles for you and the Hiyall team; opening marks it read', (
      tester,
    ) async {
      server.unread = 1;
      await launchApp(tester, api, '/profile/support/t1');
      expect(find.text('My account is locked'), findsOneWidget);
      expect(find.text('Try resetting your password'), findsOneWidget);
      expect(find.text('Hiyall team'), findsOneWidget);
      expect(api.count('GET /v1/support/threads/t1/messages'), 1);
      expect(find.byKey(const Key('support-thread-note')), findsOneWidget);
    });

    testWidgets('sends a message', (tester) async {
      await launchApp(tester, api, '/profile/support/t1');
      await tester.enterText(
        find.byKey(const Key('support-reply')),
        'Thank you',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('support-reply-send')));
      await tester.pumpAndSettle();
      expect(server.sentMessages.single, {'body': 'Thank you'});
      expect(find.text('Thank you'), findsOneWidget);
    });

    testWidgets('409 SUPPORT_THREAD_CLOSED switches to the closed state', (
      tester,
    ) async {
      await launchApp(tester, api, '/profile/support/t1');
      server.sendFails = const ApiFailure(
        'This conversation is closed.',
        409,
        'SUPPORT_THREAD_CLOSED',
      );
      await tester.enterText(find.byKey(const Key('support-reply')), 'More');
      await tester.pump();
      await tester.tap(find.byKey(const Key('support-reply-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('support-closed')), findsOneWidget);
      expect(find.byKey(const Key('support-reply')), findsNothing);
    });

    testWidgets('closing it asks first, then shows the closed state', (
      tester,
    ) async {
      await launchApp(tester, api, '/profile/support/t1');
      await tester.tap(find.byKey(const Key('support-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('support-close')));
      await tester.pumpAndSettle();
      expect(find.text('Close this conversation?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('support-close-keep')));
      await tester.pumpAndSettle();
      expect(api.count('POST /v1/support/threads/t1/close'), 0);

      await tester.tap(find.byKey(const Key('support-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('support-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('support-close-confirm')));
      await tester.pumpAndSettle();
      expect(api.count('POST /v1/support/threads/t1/close'), 1);
      expect(find.text('This conversation is closed'), findsOneWidget);
      expect(find.byKey(const Key('support-menu')), findsNothing);
    });

    testWidgets(
      'a closed conversation offers a new message in the same topic',
      (tester) async {
        server.threads.first['status'] = 'closed';
        final c = await launchApp(tester, api, '/profile/support/t1');
        expect(find.text('This conversation is closed'), findsOneWidget);
        expect(find.byKey(const Key('support-reply')), findsNothing);
        await tester.tap(find.byKey(const Key('support-start-new')));
        await tester.pumpAndSettle();
        expect(where(c), '/profile/support/new?category=account');
        final chip = tester.widget<Semantics>(
          find
              .descendant(
                of: find.byKey(const Key('support-topic-account')),
                matching: find.byType(Semantics),
              )
              .first,
        );
        expect(chip, isNotNull);
        expect(find.byKey(const Key('support-send')), findsOneWidget);
      },
    );

    testWidgets('a realtime "support" signal reads the conversation again', (
      tester,
    ) async {
      final c = await launchApp(tester, api, '/profile/support/t1');
      final before = api.count('GET /v1/support/threads/t1/messages');
      server.messages['t1']!.add(messageJson('m3', 'staff', 'Any luck?'));
      c.read(supportSignalProvider.notifier).bump();
      await tester.pumpAndSettle();
      expect(
        api.count('GET /v1/support/threads/t1/messages'),
        greaterThan(before),
      );
      expect(find.text('Any luck?'), findsOneWidget);
    });
  });

  test('a push with kind support opens the support list', () {
    final tap = PushTap.fromData({'kind': 'support'});
    expect(tap, isNotNull);
    expect(tap!.location, '/profile/support');
  });
}
