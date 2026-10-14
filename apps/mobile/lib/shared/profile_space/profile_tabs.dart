import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';

/// One tab of the Posts / Media / Vibes strip.
class ProfileContentTab extends StatelessWidget {
  final int index;
  final bool selected;
  final Color accent, muted;
  final VoidCallback onSelect;
  const ProfileContentTab({
    super.key,
    required this.index,
    required this.selected,
    required this.accent,
    required this.muted,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: InkWell(
      onTap: () {
        if (!selected) {
          HapticFeedback.selectionClick();
          onSelect();
        }
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ['Posts', 'Media', 'Vibes'][index],
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                color: selected ? null : muted,
              ),
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: Duration(
                milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 200,
              ),
              width: selected ? 16 : 4,
              height: 3,
              decoration: BoxDecoration(
                color: selected ? accent : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The body under the selected tab: provided content, the saved vibe, or an
/// empty state.
class ProfileTabContent extends StatelessWidget {
  final Profile profile;
  final int tab;
  final bool isOwner;
  final VoidCallback? onEdit;
  final Widget? Function(int tab)? contentFor;
  final Color accent, muted;
  const ProfileTabContent({
    super.key,
    required this.profile,
    required this.tab,
    required this.isOwner,
    required this.onEdit,
    required this.contentFor,
    required this.accent,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Duration(
      milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 220,
    ),
    child: _body(),
  );

  // Each variant carries its own key so the switcher animates between tabs.
  Widget _body() {
    final provided = tab < 2 ? contentFor?.call(tab) : null;
    if (provided != null) {
      return KeyedSubtree(
        key: ValueKey('profile-content-$tab'),
        child: provided,
      );
    }
    if (tab == 2 && profile.currentVibe.isNotEmpty) {
      return _SavedVibe(
        vibe: profile.currentVibe,
        isOwner: isOwner,
        onEdit: onEdit,
        accent: accent,
        muted: muted,
      );
    }
    return _EmptyTab(
      key: ValueKey('profile-empty-$tab'),
      tab: tab,
      isOwner: isOwner,
      onEdit: onEdit,
      muted: muted,
    );
  }
}

class _SavedVibe extends StatelessWidget {
  final String vibe;
  final bool isOwner;
  final VoidCallback? onEdit;
  final Color accent, muted;
  const _SavedVibe({
    required this.vibe,
    required this.isOwner,
    required this.onEdit,
    required this.accent,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('saved-vibe-content'),
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: accent.withValues(alpha: .07),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: accent.withValues(alpha: .15)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'RIGHT NOW',
          style: TextStyle(fontSize: 10, letterSpacing: 1.5, color: muted),
        ),
        const SizedBox(height: 12),
        Text(
          vibe,
          style: const TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (isOwner)
          TextButton(onPressed: onEdit, child: const Text('Change my vibe')),
      ],
    ),
  );
}

class _EmptyTab extends StatelessWidget {
  final int tab;
  final bool isOwner;
  final VoidCallback? onEdit;
  final Color muted;
  const _EmptyTab({
    super.key,
    required this.tab,
    required this.isOwner,
    required this.onEdit,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      children: [
        Icon(
          [
            Icons.layers_outlined,
            Icons.photo_library_outlined,
            Icons.auto_awesome_outlined,
          ][tab],
          size: 28,
          color: muted.withValues(alpha: .65),
        ),
        const SizedBox(height: 12),
        Text(
          tab == 0
              ? 'Nothing here yet 👀'
              : tab == 1
              ? 'Room for your memories'
              : 'A little feeling, a little you.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          tab == 0
              ? 'Your next chapter can live here.'
              : tab == 1
              ? 'A place for your shared photos and videos.'
              : isOwner
              ? 'Set your current vibe to make this space yours.'
              : 'Check back for a little of their world.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, height: 1.6, color: muted),
        ),
        if (tab == 2 && isOwner)
          TextButton(onPressed: onEdit, child: const Text('Set my vibe')),
      ],
    ),
  );
}
