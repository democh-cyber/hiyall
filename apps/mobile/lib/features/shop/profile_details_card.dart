import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/billing/billing_state.dart';
import '../../core/state.dart';
import '../../core/user_error.dart';
import '../../shared/widgets.dart';
import 'coin_pill.dart';
import 'locked_feature_sheet.dart';
import 'spend_gate.dart';

/// Shown on another member's profile whose detailed fields the server left out (`detailsLocked`). Says what it costs and what the alternatives are, and
/// unlocks only after the member confirms the price. Nothing shows unless the server says locks apply to this member.
class ProfileDetailsLockedCard extends ConsumerStatefulWidget {
  final String userId;
  const ProfileDetailsLockedCard({super.key, required this.userId});
  @override
  ConsumerState<ProfileDetailsLockedCard> createState() => _CardState();
}

class _CardState extends ConsumerState<ProfileDetailsLockedCard> {
  bool busy = false;

  Future<void> unlock() async {
    if (busy) return;
    final backend = ref.read(billingBackendProvider);
    final cost =
        ref
            .read(billingStateProvider)
            .asData
            ?.value
            .entitlements
            .profileDetailCoinCost ??
        0;
    setState(() => busy = true);
    try {
      var confirmed = cost;
      var balance = ref.read(billingStateProvider).asData?.value.balance ?? 0;
      try {
        // Ask what it costs now: the price on the server is the one that counts.
        await backend.unlockProfileDetails(widget.userId);
      } on ApiFailureDetails catch (e) {
        if (e.code != 'SPEND_CONFIRMATION_REQUIRED' &&
            e.code != 'INSUFFICIENT_COINS') {
          rethrow;
        }
        confirmed = (e.details['cost'] as num?)?.toInt() ?? cost;
        balance = (e.details['balance'] as num?)?.toInt() ?? balance;
        if (!mounted) return;
        final ok = await confirmSpend(
          context,
          title: 'See the details?',
          what: 'This shows this member’s full profile details for a while.',
          cost: confirmed,
          balance: balance,
          canOpenShop: ref.read(shopAvailableProvider),
        );
        if (!ok) return;
        final result = await backend.unlockProfileDetails(
          widget.userId,
          confirmCost: confirmed,
        );
        ref.read(billingStateProvider.notifier).applyBalance(result.balance);
      }
      ref.invalidate(otherProfileProvider(widget.userId));
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(billingStateProvider).asData?.value;
    if (state == null || !state.showsPlans) return const SizedBox.shrink();
    final cost = state.entitlements.profileDetailCoinCost;
    return VibePanel(
      key: const Key('details-locked'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_outline_rounded),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Full details are locked',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            cost > 0
                ? 'See this member’s full details for ${state.entitlements.profileDetailDays} days for ${coinsText(cost)}, or with Premium.'
                : 'Full details are part of Premium.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (cost > 0)
                FilledButton(
                  key: const Key('unlock-details'),
                  onPressed: busy ? null : unlock,
                  child: Text('Unlock for ${coinsText(cost)}'),
                ),
              OutlinedButton(
                key: const Key('details-premium'),
                onPressed: () =>
                    showLockedFeatureSheet(context, feature: 'detailedProfile'),
                child: const Text('About Premium'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
