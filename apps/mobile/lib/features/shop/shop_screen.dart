import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import '../../core/billing/billing_models.dart';
import '../../core/billing/billing_state.dart';
import '../../core/theme.dart';
import '../../core/user_error.dart';
import '../../shared/widgets.dart';
import 'coin_pill.dart';
import 'shop_labels.dart';

/// Opens a link outside the app (the store's subscription page). A provider so tests record it.
final shopLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// Where a subscription is managed or cancelled: the store it was bought in.
Uri manageSubscriptionUri(PlanInfo plan, PurchaseStore fallback) {
  final google = plan.store == null
      ? fallback == PurchaseStore.googlePlay
      : plan.store == 'google_play';
  return google
      ? Uri.https('play.google.com', '/store/account/subscriptions', {
          'sku': ?plan.productId,
          'package': 'app.hiyall.hiyall',
        })
      : Uri.https('apps.apple.com', '/account/subscriptions');
}

/// The Shop: coin packs, Premium plans, what each plan includes, ways to earn coins, restore, and the history. Adults only: for anyone the server
/// does not say may shop, the screen sends them away and shows nothing.
class ShopScreen extends ConsumerWidget {
  const ShopScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billing = ref.watch(billingStateProvider);
    return billing.when(
      loading: () => const Center(child: VibeLoading()),
      error: (error, _) => ReadingWidth(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const _ShopBack(),
            FailureCard(
              error: error,
              retry: () => ref.invalidate(billingStateProvider),
            ),
          ],
        ),
      ),
      data: (state) =>
          state.shop && ref.watch(purchaseServiceProvider).supported
          ? _ShopBody(state)
          : const _Leave(),
    );
  }
}

/// Anyone who is not allowed in leaves at once; nothing of the shop is built for them.
class _Leave extends StatefulWidget {
  const _Leave();
  @override
  State<_Leave> createState() => _LeaveState();
}

class _LeaveState extends State<_Leave> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.go('/home');
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _ShopBack extends StatelessWidget {
  const _ShopBack();
  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: TextButton.icon(
      onPressed: () => context.go('/profile/settings'),
      icon: const Icon(Icons.arrow_back),
      label: const Text('Settings'),
    ),
  );
}

class _ShopBody extends ConsumerWidget {
  final BillingState state;
  const _ShopBody(this.state);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(purchaseControllerProvider);
    final products = ref.watch(storeProductsProvider);
    final store = ref.watch(purchaseStoreProvider);
    final storeName = store == PurchaseStore.googlePlay
        ? 'Google Play'
        : 'the App Store';
    String priceOf(String storeId) => products.when(
      data: (m) => m[storeId]?.price ?? 'Unavailable',
      loading: () => '…',
      error: (_, _) => 'Unavailable',
    );
    String idOf(String google, String apple) =>
        store == PurchaseStore.googlePlay ? google : apple;
    final controller = ref.read(purchaseControllerProvider.notifier);
    return ReadingWidth(
      child: ListView(
        key: const Key('shop'),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        children: [
          const _ShopBack(),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Shop',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              CoinPill(state.balance),
            ],
          ),
          if (ui.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(
                liveRegion: true,
                child: VibePanel(
                  key: const Key('shop-message'),
                  padding: const EdgeInsets.all(14),
                  color: ui.messageIsError
                      ? Theme.of(context).colorScheme.errorContainer
                      : VibeColors.mint,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          ui.message!,
                          style: TextStyle(
                            color: ui.messageIsError
                                ? Theme.of(context).colorScheme.onErrorContainer
                                : VibeColors.ink,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Dismiss',
                        onPressed: controller.clearMessage,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SectionTitle('Coins'),
          Text(
            'Use coins to start extra chats and to see a member’s full profile details. Coins don’t expire.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          for (final pack in state.coinPacks)
            _PackTile(
              pack: pack,
              price: priceOf(idOf(pack.googleProductId, pack.appProductId)),
              busy: ui.busy,
              buying: ui.buying == pack.id,
              onBuy: () => controller.buy(pack.id),
            ),
          const SectionTitle('Premium'),
          _PlanStatus(state.plan),
          Text(
            'Premium renews automatically until you cancel it. You can cancel any time in $storeName; you keep Premium until the period you paid for ends.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          for (final plan in state.plans)
            _PlanTile(
              plan: plan,
              price: priceOf(idOf(plan.googleProductId, plan.appProductId)),
              busy: ui.busy,
              buying: ui.buying == plan.id,
              owned: state.plan.isPremium,
              onBuy: () => controller.buy(plan.id),
            ),
          if (state.benefits.isNotEmpty) ...[
            const SectionTitle('Free and Premium'),
            _BenefitsTable(state.benefits),
          ],
          const _EarnSection(),
          const SectionTitle('Your coins'),
          const _History(),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('restore-purchases'),
                onPressed: ui.busy ? null : controller.restore,
                icon: ui.restoring
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.restore_rounded),
                label: const Text('Restore purchases'),
              ),
              if (state.plan.hasSubscription)
                OutlinedButton.icon(
                  key: const Key('manage-subscription'),
                  onPressed: () => ref.read(shopLauncherProvider)(
                    manageSubscriptionUri(state.plan, store),
                  ),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Manage or cancel Premium'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Payments are made through $storeName. Purchases are for adults.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _PackTile extends StatelessWidget {
  final CoinPack pack;
  final String price;
  final bool busy, buying;
  final VoidCallback onBuy;
  const _PackTile({
    required this.pack,
    required this.price,
    required this.busy,
    required this.buying,
    required this.onBuy,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: VibePanel(
      key: Key('pack-${pack.id}'),
      padding: const EdgeInsets.all(16),
      child: _ProductRow(
        icon: Icons.toll_rounded,
        text: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              coinsText(pack.total),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            Text(
              pack.bonusCoins > 0
                  ? '${pack.name}: ${pack.coins} plus ${pack.bonusCoins} extra'
                  : pack.name,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        action: FilledButton(
          key: Key('buy-${pack.id}'),
          onPressed: busy || price == 'Unavailable' ? null : onBuy,
          child: buying ? const _Spinner() : Text(price),
        ),
      ),
    ),
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 16,
    height: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

class _PlanStatus extends StatelessWidget {
  final PlanInfo plan;
  const _PlanStatus(this.plan);
  @override
  Widget build(BuildContext context) {
    if (!plan.hasSubscription) return const SizedBox.shrink();
    final end = plan.currentPeriodEnd;
    final text = switch (plan.status) {
      'active' when plan.autoRenew && end != null =>
        'Premium is on. It renews on ${dateText(end)}.',
      'active' when end != null =>
        'Premium is on until ${dateText(end)}. It won’t renew.',
      'grace' => 'The store couldn’t take your last payment. You still have Premium while it tries again.',
      'on_hold' => 'Premium is paused because the payment failed. Fix your payment method in the store to get it back.',
      'paused' => 'Premium is paused in the store.',
      'expired' || 'revoked' => 'Your Premium has ended.',
      _ => 'Premium',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        key: const Key('plan-status'),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _PlanTile extends StatelessWidget {
  final PremiumPlan plan;
  final String price;
  final bool busy, buying, owned;
  final VoidCallback onBuy;
  const _PlanTile({
    required this.plan,
    required this.price,
    required this.busy,
    required this.buying,
    required this.owned,
    required this.onBuy,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: VibePanel(
      key: Key('plan-${plan.id}'),
      padding: const EdgeInsets.all(16),
      child: _ProductRow(
        icon: Icons.workspace_premium_outlined,
        text: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              plan.name,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            Text(
              '$price every ${periodText(plan.periodMonths)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        action: OutlinedButton(
          key: Key('buy-${plan.id}'),
          onPressed: busy || owned || price == 'Unavailable' ? null : onBuy,
          child: buying ? const _Spinner() : Text(owned ? 'Active' : 'Choose'),
        ),
      ),
    ),
  );
}

class _BenefitsTable extends StatelessWidget {
  final List<Benefit> rows;
  const _BenefitsTable(this.rows);
  @override
  Widget build(BuildContext context) {
    final head = Theme.of(context).textTheme.labelLarge;
    return VibePanel(
      key: const Key('benefits-table'),
      padding: const EdgeInsets.all(12),
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(2.2),
          1: FlexColumnWidth(1.4),
          2: FlexColumnWidth(1.4),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            children: [
              const SizedBox.shrink(),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text('Free', style: head),
              ),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text('Premium', style: head),
              ),
            ],
          ),
          for (final b in rows)
            TableRow(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(benefitTitle(b)),
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(benefitCell(b.free)),
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    benefitCell(b.premium),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _EarnSection extends ConsumerWidget {
  const _EarnSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(billingStateProvider).asData?.value ?? BillingState.none;
    final ads = ref.watch(adsControllerProvider);
    final adsService = ref.watch(adsServiceProvider);
    final showAd =
        state.ads.enabled && state.adsEligible && adsService.configured;
    final showBonus = state.profileBonusCoins > 0 && !state.profileBonusClaimed;
    if (!showAd && !showBonus) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Earn coins'),
        if (showAd)
          VibePanel(
            key: const Key('earn-ad'),
            padding: const EdgeInsets.all(16),
            child: _ProductRow(
              icon: Icons.play_circle_outline_rounded,
              text: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Watch a short video for ${coinsText(state.ads.coinsPerAd)}',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    state.ads.remainingToday > 0
                        ? '${state.ads.remainingToday} left today'
                        : 'You’ve watched all of today’s videos',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              action: OutlinedButton(
                key: const Key('watch-ad'),
                onPressed: ads.busy || state.ads.remainingToday <= 0
                    ? null
                    : () => ref.read(adsControllerProvider.notifier).watch(),
                child: ads.busy ? const _Spinner() : const Text('Watch'),
              ),
            ),
          ),
        if (ads.message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Semantics(
              liveRegion: true,
              child: Text(ads.message!, key: const Key('ads-message')),
            ),
          ),
        if (showBonus) ...[
          const SizedBox(height: 10),
          VibePanel(
            key: const Key('earn-profile'),
            padding: const EdgeInsets.all(16),
            child: _ProductRow(
              icon: Icons.face_6_outlined,
              text: Text(
                'Finish your profile (photo, a few words, an interest and a language) for ${coinsText(state.profileBonusCoins)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              action: OutlinedButton(
                key: const Key('claim-profile-bonus'),
                onPressed: () => _claim(context, ref),
                child: const Text('Claim'),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _claim(BuildContext context, WidgetRef ref) async {
    try {
      final result = await ref.read(billingBackendProvider).claimProfileBonus();
      if (result.granted) {
        ref.read(billingStateProvider.notifier).applyBalance(result.balance);
      }
      await ref.read(billingStateProvider.notifier).refresh();
      if (context.mounted) {
        showMessage(
          context,
          result.granted ? '${coinsText(result.coins)} added.' : 'Your profile isn’t complete yet. Add a photo, a few words, an interest and a language.',
        );
      }
    } catch (e) {
      if (context.mounted) showFailure(context, e);
    }
  }
}

class _History extends ConsumerStatefulWidget {
  const _History();
  @override
  ConsumerState<_History> createState() => _HistoryState();
}

class _HistoryState extends ConsumerState<_History> {
  final rows = <LedgerEntry>[];
  String? next;
  bool loaded = false, loading = false;
  Object? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await ref.read(billingBackendProvider).history(cursor: next);
      rows.addAll(page.items);
      next = page.nextCursor;
      loaded = true;
    } catch (e) {
      error = e;
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Row(
        children: [
          Expanded(child: Text(friendlyError(error))),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
    }
    if (!loaded) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (rows.isEmpty) {
      return const Text(
        'Nothing yet. Coins you get or spend will show up here.',
        key: Key('history-empty'),
      );
    }
    return Column(
      key: const Key('history'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(ledgerLabel(e.reason)),
            subtitle: Text(dateText(e.createdAt)),
            trailing: Text(
              e.delta > 0 ? '+${e.delta}' : '${e.delta}',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: e.delta > 0 ? VibeColors.success : null,
              ),
            ),
          ),
        if (next != null)
          TextButton(
            key: const Key('history-more'),
            onPressed: loading ? null : _load,
            child: const Text('Show more'),
          ),
      ],
    );
  }
}

/// An icon, some words and one action: side by side when there is room, and the action under the words when the screen is narrow or the
/// text is large (320 px at text scale 2.0 must not overflow).
class _ProductRow extends StatelessWidget {
  final IconData icon;
  final Widget text, action;
  const _ProductRow({
    required this.icon,
    required this.text,
    required this.action,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
      final stacked = box.maxWidth < 280 + (scale - 1) * 120;
      final head = Row(
        children: [
          Icon(icon, size: 28),
          const SizedBox(width: 14),
          Expanded(child: text),
        ],
      );
      if (!stacked) {
        return Row(
          children: [
            Expanded(child: head),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: action,
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          head,
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: action,
            ),
          ),
        ],
      );
    },
  );
}
