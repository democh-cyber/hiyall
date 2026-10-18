import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// The member's coin balance as a small pill. Shown only where plans are shown (see [showsPlansProvider]).
class CoinPill extends StatelessWidget {
  final int balance;
  const CoinPill(this.balance, {super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: balance == 1 ? '1 coin' : '$balance coins',
    excludeSemantics: true,
    child: Container(
      key: const Key('coin-pill'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: VibeColors.lime,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.toll_rounded, size: 16, color: VibeColors.ink),
          const SizedBox(width: 6),
          Text(
            '$balance',
            style: const TextStyle(
              color: VibeColors.ink,
              fontWeight: FontWeight.w800,
              fontSize: 14,
            ),
          ),
        ],
      ),
    ),
  );
}

String coinsText(int n) => n == 1 ? '1 coin' : '$n coins';
