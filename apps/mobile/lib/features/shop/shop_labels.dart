import '../../core/billing/billing_models.dart';

/// Wording for the Shop: ledger reasons and the Free versus Premium table. Our own words; the server sends keys and a fallback title.
String ledgerLabel(String reason) => switch (reason) {
  'purchase' => 'Coins you bought',
  'reward_ad' => 'Video reward',
  'profile_completion' => 'Profile bonus',
  'review_bonus' => 'Bonus',
  'spend_chat_slot' => 'Started an extra chat',
  'spend_profile_detail' => 'Unlocked profile details',
  'refund' => 'Refund',
  'refund_reversal' => 'Refund undone',
  'admin_adjust' => 'Adjustment by support',
  _ => 'Coins',
};

String benefitTitle(Benefit b) => switch (b.key) {
  'newChats' => 'Start new chats',
  'profileDetails' => 'See profile details',
  'autoTranslate' => 'Translate chats automatically',
  'visitorsList' => 'See who visited you',
  'nearbyFilter' => 'Filters in Nearby',
  'genderFilter' => 'Filter people by gender',
  'groupChat' => 'Group chats',
  'uploads' => 'Photo uploads',
  'storage' => 'Photo storage',
  _ => b.title,
};

/// One cell as words. [included] is "Yes" and [notIncluded] "No" so the table reads without colour or icons.
String benefitCell(BenefitCell c) => switch (c.kind) {
  BenefitKind.included => 'Yes',
  BenefitKind.notIncluded => 'No',
  BenefitKind.unlimited => 'Unlimited',
  BenefitKind.limit =>
    c.unit == 'day'
        ? '${c.value} a day'
        : '${c.value} ${c.unit.isEmpty ? '' : c.unit}'.trim(),
  BenefitKind.coins =>
    '${c.value} ${c.value == 1 ? 'coin' : 'coins'} each, for ${c.days} days',
};

String periodText(int months) => switch (months) {
  1 => '1 month',
  12 => '1 year',
  _ => '$months months',
};

String dateText(DateTime t) {
  final l = t.toLocal();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${l.day} ${months[l.month - 1]} ${l.year}';
}
