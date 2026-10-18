import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/billing/billing_state.dart';

/// What each Premium feature is, in plain words.
String premiumFeatureName(String feature) => switch (feature) {
  'genderFilter' => 'Filtering people by gender',
  'nearbyFilter' => 'Filters in Nearby',
  'visitorsList' => 'Seeing who visited your profile',
  'detailedProfile' => 'Full profile details',
  'autoTranslate' => 'Automatic chat translation',
  'groupChat' => 'Group chats',
  _ => 'This feature',
};

/// Explains plainly that [feature] is part of Premium. Only ever shown when the server said so (402 PREMIUM_REQUIRED, which it sends only when plans
/// are enforced for an adult), so a member who cannot buy never gets here. "Not now" is as prominent as the way to Premium.
Future<void> showLockedFeatureSheet(
  BuildContext context, {
  required String feature,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  if (!container.read(shopAvailableProvider)) return Future.value();
  final state = container.read(billingStateProvider).asData?.value;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        child: Column(
          key: const Key('locked-feature'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              premiumFeatureName(feature),
              style: Theme.of(sheet).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              'This is part of Premium. Premium is a subscription you can cancel any time in the store.',
            ),
            if (feature == 'detailedProfile' &&
                (state?.entitlements.profileDetailCoinCost ?? 0) > 0) ...[
              const SizedBox(height: 8),
              Text(
                'You can also unlock one profile’s details with ${state!.entitlements.profileDetailCoinCost} ${state.entitlements.profileDetailCoinCost == 1 ? 'coin' : 'coins'}.',
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('locked-see-premium'),
              onPressed: () {
                Navigator.pop(sheet);
                context.go('/shop');
              },
              child: const Text('See Premium'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('locked-not-now'),
              onPressed: () => Navigator.pop(sheet),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    ),
  );
}
