import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/billing/billing_state.dart';
import '../../core/chat/chat_api.dart' show ChatFailure;
import 'coin_pill.dart';

/// Asks the member to confirm paying [cost] coins for [what], showing the cost and their balance. True only on an explicit "Spend".
/// Nothing is ever spent without this answer. When the balance is short it says so and offers the Shop (for a member who has one)
/// instead of a spend button.
Future<bool> confirmSpend(
  BuildContext context, {
  required String title,
  required String what,
  required int cost,
  required int balance,
  bool canOpenShop = true,
}) async {
  final enough = balance >= cost;
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        child: Column(
          key: const Key('spend-confirm'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(sheet).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(what),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Cost', style: Theme.of(sheet).textTheme.labelLarge),
                Text(coinsText(cost), key: const Key('spend-cost')),
                Text('You have', style: Theme.of(sheet).textTheme.labelLarge),
                CoinPill(balance),
              ],
            ),
            if (!enough) ...[
              const SizedBox(height: 12),
              Text(
                'You don’t have enough coins for this yet.',
                key: const Key('spend-short'),
                style: TextStyle(color: Theme.of(sheet).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            if (enough)
              FilledButton(
                key: const Key('spend-confirm-yes'),
                onPressed: () => Navigator.pop(sheet, true),
                child: Text('Spend ${coinsText(cost)}'),
              )
            else if (canOpenShop)
              FilledButton(
                key: const Key('spend-open-shop'),
                onPressed: () {
                  Navigator.pop(sheet, false);
                  context.go('/shop');
                },
                child: const Text('Get coins'),
              ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('spend-cancel'),
              onPressed: () => Navigator.pop(sheet, false),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    ),
  );
  return result == true;
}

/// Opens a chat through [open] (the chat engine's `open`, given the confirmed price when there is one), asking first when the server says starting it
/// costs coins (HTTP 402). Returns the conversation id, or null when the member said no, did not have enough coins, or cancelled.
Future<String?> openChatConfirmingSpend(
  BuildContext context,
  WidgetRef ref, {
  required Future<String> Function(int? confirmCost) open,
}) async {
  try {
    return await open(null);
  } on ChatFailure catch (e) {
    if (e.status != 402 ||
        (e.code != 'SPEND_CONFIRMATION_REQUIRED' &&
            e.code != 'INSUFFICIENT_COINS')) {
      rethrow;
    }
    final cost = (e.details?['cost'] as num?)?.toInt();
    final balance = (e.details?['balance'] as num?)?.toInt() ?? 0;
    if (cost == null || !context.mounted) rethrow;
    final ok = await confirmSpend(
      context,
      title: 'Start this chat?',
      what: 'You’ve started all your free chats for today. Another one costs coins, or you can wait until tomorrow.',
      cost: cost,
      balance: balance,
      canOpenShop: ref.read(shopAvailableProvider),
    );
    if (!ok) return null;
    return open(cost);
  }
}
