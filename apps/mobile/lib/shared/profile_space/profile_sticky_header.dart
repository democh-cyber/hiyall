import 'package:flutter/material.dart';

import '../../core/api.dart';
import 'profile_avatar.dart';

class ProfileStickyHeader extends SliverPersistentHeaderDelegate {
  final Profile profile;
  final ScrollController scroll;
  final Color accent;
  final bool dark, isOwner;
  final double height;
  final VoidCallback? onSettings, onOptions;
  const ProfileStickyHeader({
    required this.profile,
    required this.scroll,
    required this.accent,
    required this.dark,
    required this.height,
    required this.isOwner,
    this.onSettings,
    this.onOptions,
  });
  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Container(
    height: height,
    color: Theme.of(context).scaffoldBackgroundColor,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Row(
      children: [
        Expanded(
          child: AnimatedBuilder(
            animation: scroll,
            builder: (context, _) {
              final collapsed = scroll.hasClients && scroll.offset > 128;
              return AnimatedSwitcher(
                duration: Duration(
                  milliseconds: MediaQuery.disableAnimationsOf(context)
                      ? 0
                      : 220,
                ),
                child: collapsed
                    ? Row(
                        key: const ValueKey('collapsed-profile-identity'),
                        children: [
                          ProfileAvatar(
                            profile: profile,
                            accent: accent,
                            size: 32,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              profile.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'SpaceGrotesk',
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      )
                    : Align(
                        key: const ValueKey('expanded-profile-identity'),
                        alignment: AlignmentDirectional.centerStart,
                        // The bar has a fixed height; at large text sizes
                        // the label shrinks to fit rather than spilling out.
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerStart,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isOwner
                                    ? 'MY DIGITAL SPACE'
                                    : 'THEIR DIGITAL SPACE',
                                style: TextStyle(
                                  fontSize: 10,
                                  letterSpacing: 2,
                                  fontWeight: FontWeight.w800,
                                  color: dark
                                      ? const Color(0xffa7b19f)
                                      : const Color(0xff69725f),
                                ),
                              ),
                              if (isOwner) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Main character. You.',
                                  style: TextStyle(
                                    fontSize: 9,
                                    height: 1.4,
                                    color: dark
                                        ? const Color(0xffa7b19f)
                                        : const Color(0xff69725f),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
              );
            },
          ),
        ),
        if (isOwner)
          IconButton(
            tooltip: 'Your space settings',
            onPressed: onSettings,
            icon: const Icon(Icons.tune_rounded, size: 22),
          ),
        if (!isOwner && onOptions != null)
          IconButton(
            key: const Key('profile-options'),
            tooltip: 'Profile options',
            onPressed: onOptions,
            icon: const Icon(Icons.more_horiz_rounded),
          ),
      ],
    ),
  );
  @override
  bool shouldRebuild(ProfileStickyHeader oldDelegate) =>
      profile != oldDelegate.profile ||
      accent != oldDelegate.accent ||
      dark != oldDelegate.dark ||
      height != oldDelegate.height ||
      isOwner != oldDelegate.isOwner ||
      onSettings != oldDelegate.onSettings ||
      onOptions != oldDelegate.onOptions;
}
