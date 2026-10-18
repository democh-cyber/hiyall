import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/billing/billing_state.dart';
import '../../shared/widgets.dart';
import 'coin_pill.dart';

/// The Shop entry in Settings, with the coin balance and the plan. Nothing at all unless the server says this member may shop (an adult, plans on,
/// a store configured, a phone): then it also starts listening for purchases the store hands over.
class BillingSettingsGroup extends ConsumerWidget {
  const BillingSettingsGroup({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(shopAvailableProvider)) return const SizedBox.shrink();
    ref.watch(
      purchaseControllerProvider,
    ); // listens for purchases the store re-delivers
    final state = ref.watch(billingStateProvider).asData?.value;
    if (state == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: VibePanel(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          key: const Key('settings-shop'),
          leading: const Icon(Icons.toll_rounded),
          title: const Text(
            'Shop',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            state.plan.isPremium ? 'Premium is on' : 'Coins and Premium',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CoinPill(state.balance),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
          onTap: () => context.go('/shop'),
        ),
      ),
    );
  }
}
