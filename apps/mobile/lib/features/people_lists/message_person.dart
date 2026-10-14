import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets.dart';
import '../chat.dart';

/// Starts a chat with [userId], as the Message button on a profile does.
Future<void> messagePerson(
  BuildContext context,
  WidgetRef ref,
  String userId,
  String name,
) async {
  if (!chatSupported) {
    showMessage(context, 'Chats are available in the Android and iOS apps.');
    return;
  }
  try {
    final engine = await ref.read(chatEngineProvider.future);
    final id = await engine!.open(userId);
    if (context.mounted) {
      context.go(
        '/chats/$id?peer=${Uri.encodeQueryComponent(userId)}&name=${Uri.encodeQueryComponent(name)}',
      );
    }
  } catch (e) {
    if (context.mounted) showMessage(context, chatError(e));
  }
}
