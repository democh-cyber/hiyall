import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/theme.dart';
import 'profile_space/profile_details.dart';
import 'profile_space/profile_gallery.dart';
import 'profile_space/profile_hero.dart';
import 'profile_space/profile_sections.dart';
import 'profile_space/profile_sticky_header.dart';
import 'profile_space/profile_tabs.dart';
import 'profile_stats.dart';

export 'profile_space/profile_share.dart' show shareProfile;
export 'profile_space/profile_skeleton.dart' show ProfileSkeleton;

Color profileAccent(Profile profile) => switch (profile.profileAccent) {
  'violet' => VibeColors.lilac,
  'cyan' => const Color(0xff9bded6),
  _ => VibeColors.lime,
};

/// Shared owner/visitor profile presentation. Visitor fields must come from the
/// viewer-filtered endpoint; this widget never fetches an owner's private data.
class ProfileSpace extends StatefulWidget {
  final Profile profile;
  final bool isOwner;
  final VoidCallback? onEdit, onSettings, onOptions;

  /// Where each tappable stat leads; a stat without an entry is a plain number.
  final ProfileStatActions statActions;

  /// Content for the Posts (0) and Media (1) tabs; null keeps the empty state.
  final Widget? Function(int tab)? contentFor;
  const ProfileSpace({
    super.key,
    required this.profile,
    this.isOwner = false,
    this.onEdit,
    this.onSettings,
    this.onOptions,
    this.contentFor,
    this.statActions = const {},
  });
  @override
  State<ProfileSpace> createState() => _ProfileSpaceState();
}

class _ProfileSpaceState extends State<ProfileSpace> {
  final scroll = ScrollController();
  int tab = 0;
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = profileAccent(p);
    final ink = dark ? const Color(0xfff1f3e9) : VibeColors.ink;
    final muted = dark ? const Color(0xffa7b19f) : const Color(0xff69725f);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    // Keep ink local to the profile, including when parent routes are offstage.
    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: CustomScrollView(
            controller: scroll,
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: ProfileStickyHeader(
                  profile: p,
                  scroll: scroll,
                  accent: accent,
                  dark: dark,
                  height: 56 + (scale - 1) * 20,
                  isOwner: widget.isOwner,
                  onSettings: widget.onSettings,
                  onOptions: widget.onOptions,
                ),
              ),
              SliverToBoxAdapter(
                child: ProfileHero(
                  profile: p,
                  isOwner: widget.isOwner,
                  onEdit: widget.onEdit,
                  statActions: widget.statActions,
                  scroll: scroll,
                  accent: accent,
                  ink: ink,
                  muted: muted,
                ),
              ),
              if (p.photos.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: ProfileGalleryStrip(photos: p.photos),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: _body(p, dark, accent, muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(Profile p, bool dark, Color accent, Color muted) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.isOwner && p.visitorsVisible) ...[
          RecentVisitorsEntry(userId: p.userId),
          const SizedBox(height: 24),
        ],
        ProfileAbout(
          profile: p,
          isOwner: widget.isOwner,
          onEdit: widget.onEdit,
          muted: muted,
        ),
        if (widget.isOwner || p.interests.isNotEmpty) ...[
          const SizedBox(height: 24),
          ProfileInterests(
            profile: p,
            isOwner: widget.isOwner,
            onEdit: widget.onEdit,
            muted: muted,
          ),
        ],
        if (p.personalityTags.isNotEmpty) ...[
          const SizedBox(height: 24),
          ProfilePersonality(tags: p.personalityTags, muted: muted),
        ],
        if (p.languages.isNotEmpty) ...[
          const SizedBox(height: 24),
          ProfileLanguages(languages: p.languages, muted: muted),
        ],
        const SizedBox(height: 32),
        ProfileSectionTitle(
          widget.isOwner ? 'MY WORLD' : 'THEIR WORLD',
          muted: muted,
        ),
        Row(
          children: [
            for (var i = 0; i < 3; i++)
              Expanded(
                child: ProfileContentTab(
                  index: i,
                  selected: i == tab,
                  accent: accent,
                  muted: muted,
                  onSelect: () => setState(() => tab = i),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        ProfileTabContent(
          profile: p,
          tab: tab,
          isOwner: widget.isOwner,
          onEdit: widget.onEdit,
          contentFor: widget.contentFor,
          accent: accent,
          muted: muted,
        ),
      ],
    );
  }
}
