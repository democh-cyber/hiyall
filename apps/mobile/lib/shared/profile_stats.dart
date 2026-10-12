import 'package:flutter/material.dart';

import '../core/api.dart';

/// The four numbers under a profile's name. Each can open the list behind it.
enum ProfileStat { following, followers, visitors, stories }

/// What a tappable stat opens. A stat with no entry is a plain number, so
/// giving one a destination is one more entry in the map.
typedef ProfileStatActions = Map<ProfileStat, VoidCallback>;

String _shortCount(int value) {
  if (value < 1000) return '$value';
  final unit = value >= 1000000 ? 'M' : 'K';
  final number = value / (unit == 'M' ? 1000000 : 1000);
  return '${number.toStringAsFixed(number < 10 ? 1 : 0).replaceFirst(RegExp(r'\.0$'), '')}$unit';
}

/// The spoken form: "7 followers", or "1 follower, opens the list" when it opens.
String profileStatLabel(ProfileStat stat, int value, {required bool opens}) {
  final one = value == 1;
  final noun = switch (stat) {
    ProfileStat.following => 'following',
    ProfileStat.followers => one ? 'follower' : 'followers',
    ProfileStat.visitors => one ? 'visitor' : 'visitors',
    ProfileStat.stories => one ? 'story' : 'stories',
  };
  final tail = switch (stat) {
    ProfileStat.stories => 'opens the stories',
    _ => 'opens the list',
  };
  return opens ? '$value $noun, $tail' : '$value $noun';
}

/// Following, Followers, Visitors and Stories. A stat with an entry in
/// [actions] is a whole-cell button (48 dp tall, ripple, focusable on the web,
/// a small chevron); the others are plain numbers.
class ProfileStatsRow extends StatelessWidget {
  final ProfileSocialStats stats;
  final ProfileStatActions actions;
  final Color ink, muted;

  /// A calm line under the row, for example when a list is not shared.
  final String? note;
  final double labelSize;
  const ProfileStatsRow({
    super.key,
    required this.stats,
    required this.ink,
    required this.muted,
    this.actions = const {},
    this.note,
    this.labelSize = 11,
  });

  int _value(ProfileStat stat) => switch (stat) {
    ProfileStat.following => stats.following,
    ProfileStat.followers => stats.followers,
    ProfileStat.visitors => stats.visitors,
    ProfileStat.stories => stats.stories,
  };

  static const _labels = {
    ProfileStat.following: 'Following',
    ProfileStat.followers: 'Followers',
    ProfileStat.visitors: 'Visitors',
    ProfileStat.stories: 'Stories',
  };

  @override
  Widget build(BuildContext context) {
    Widget cell(ProfileStat stat) {
      final value = _value(stat);
      final open = actions[stat];
      final content = Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _shortCount(value),
              style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                fontSize: 22,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _labels[stat]!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: labelSize,
                      height: 1.4,
                      color: muted,
                    ),
                  ),
                ),
                if (open != null)
                  Icon(Icons.chevron_right_rounded, size: 14, color: muted),
              ],
            ),
          ],
        ),
      );
      return Expanded(
        child: Semantics(
          key: ValueKey('stat-${stat.name}'),
          container: true,
          button: open != null,
          label: profileStatLabel(stat, value, opens: open != null),
          excludeSemantics: true,
          child: open == null
              ? Center(child: content)
              : InkWell(
                  key: ValueKey('stat-open-${stat.name}'),
                  onTap: open,
                  borderRadius: BorderRadius.circular(14),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Center(child: content),
                  ),
                ),
        ),
      );
    }

    final row = Row(
      key: const ValueKey('profile-social-stats'),
      children: [for (final stat in ProfileStat.values) cell(stat)],
    );
    if (note == null) return row;
    return Column(
      children: [
        row,
        const SizedBox(height: 4),
        Text(
          note!,
          key: const ValueKey('profile-stats-note'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, height: 1.4, color: muted),
        ),
      ],
    );
  }
}
