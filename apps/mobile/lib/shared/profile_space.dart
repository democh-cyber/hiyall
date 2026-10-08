import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/profile_labels.dart';
import '../core/theme.dart';

Color profileAccent(Profile profile) => switch (profile.profileAccent) {
  'violet' => VibeColors.lilac,
  'cyan' => const Color(0xff9bded6),
  _ => VibeColors.lime,
};

Future<void> shareProfile(BuildContext context, Profile profile) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Share a little of your world',
              style: Theme.of(sheet).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text('@${profile.username}'),
            const SizedBox(height: 12),
            const Text(
              'Your privacy settings still decide who can see your profile.',
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy username'),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: '@${profile.username}'),
                );
                if (sheet.mounted) Navigator.pop(sheet);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Username copied.')),
                  );
                }
              },
            ),
            if (kIsWeb)
              OutlinedButton.icon(
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('Copy profile link'),
                onPressed: () async {
                  final link = Uri.base
                      .replace(fragment: '/discover/person/${profile.userId}')
                      .toString();
                  await Clipboard.setData(ClipboardData(text: link));
                  if (sheet.mounted) Navigator.pop(sheet);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Profile link copied.')),
                    );
                  }
                },
              ),
          ],
        ),
      ),
    ),
  );
}

/// Shared owner/visitor profile presentation. Visitor fields must come from the
/// viewer-filtered endpoint; this widget never fetches an owner's private data.
class ProfileSpace extends StatefulWidget {
  final Profile profile;
  final bool isOwner;
  final VoidCallback? onEdit, onSettings, onOptions;
  const ProfileSpace({
    super.key,
    required this.profile,
    this.isOwner = false,
    this.onEdit,
    this.onSettings,
    this.onOptions,
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
                delegate: _ProfileStickyHeader(
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
              SliverToBoxAdapter(child: _hero(context, p, accent, ink, muted)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _about(context, p, muted),
                      if (widget.isOwner || p.interests.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        _sectionTitle(
                          'MY INTERESTS',
                          muted,
                          action: widget.isOwner
                              ? IconButton(
                                  tooltip: 'Edit interests',
                                  onPressed: widget.onEdit,
                                  icon: const Icon(Icons.add_rounded, size: 20),
                                )
                              : null,
                        ),
                        if (p.interests.isNotEmpty)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (var i = 0; i < p.interests.length; i++)
                                _interest(p.interests[i], i, dark, accent),
                            ],
                          )
                        else
                          Text(
                            'What are you into?',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.5,
                              color: muted,
                            ),
                          ),
                      ],
                      if (p.languages.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        _sectionTitle('LANGUAGES', muted),
                        Wrap(
                          spacing: 24,
                          runSpacing: 12,
                          children: [
                            for (final language in p.languages)
                              Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: languageLabel(language.code),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (language.level.isNotEmpty)
                                      TextSpan(
                                        text:
                                            ' · ${languageLevels[language.level] ?? 'Not specified'}',
                                        style: TextStyle(color: muted),
                                      ),
                                  ],
                                ),
                                style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.5,
                                ),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 32),
                      _sectionTitle(
                        widget.isOwner ? 'MY WORLD' : 'THEIR WORLD',
                        muted,
                      ),
                      Row(
                        children: [
                          for (var i = 0; i < 3; i++)
                            Expanded(child: _contentTab(i, accent, muted)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      AnimatedSwitcher(
                        duration: Duration(
                          milliseconds: MediaQuery.disableAnimationsOf(context)
                              ? 0
                              : 220,
                        ),
                        child: _content(p, accent, muted),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hero(
    BuildContext context,
    Profile p,
    Color accent,
    Color ink,
    Color muted,
  ) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduced ? 1 : 0, end: 1),
      duration: Duration(milliseconds: reduced ? 0 : 260),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - value)),
          child: child,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: p.profilePattern == 'plain'
                ? null
                : RadialGradient(
                    center: const Alignment(0, -.75),
                    radius: .8,
                    colors: [
                      accent.withValues(alpha: dark ? .07 : .16),
                      accent.withValues(alpha: 0),
                    ],
                  ),
          ),
          child: Stack(
            children: [
              if (p.profilePattern == 'orbit')
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _ProfileOrbitPainter(
                        accent.withValues(alpha: .12),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                child: Column(
                  children: [
                    AnimatedBuilder(
                      animation: scroll,
                      builder: (context, child) {
                        final progress = reduced || !scroll.hasClients
                            ? 0.0
                            : scroll.offset.clamp(0, 160) / 160;
                        return SizedBox(
                          height: 112 * (1 - progress * .18),
                          child: Transform.scale(
                            scale: 1 - progress * .18,
                            child: child,
                          ),
                        );
                      },
                      child: _ProfileAvatar(profile: p, accent: accent),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      p.displayName,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontSize: 34,
                        height: 1.08,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '@${p.username}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: .4,
                        color: muted,
                      ),
                    ),
                    if (p.headline.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        p.headline,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          height: 1.4,
                          fontWeight: FontWeight.w700,
                          color: ink,
                        ),
                      ),
                    ],
                    if (p.bio.isNotEmpty || widget.isOwner) ...[
                      const SizedBox(height: 4),
                      Text(
                        p.bio.isEmpty
                            ? 'Your story starts with a few words.'
                            : p.bio,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: ink.withValues(alpha: .85),
                        ),
                      ),
                    ],
                    if (p.quote.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        '“${p.quote}”',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: muted,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        if (widget.isOwner)
                          FilledButton.icon(
                            onPressed: widget.onEdit,
                            style: FilledButton.styleFrom(
                              backgroundColor: accent,
                              foregroundColor: VibeColors.ink,
                              minimumSize: const Size(128, 48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              visualDensity: VisualDensity.standard,
                            ),
                            icon: const Icon(Icons.edit_outlined, size: 16),
                            label: const Text('Edit profile'),
                          ),
                        if (!widget.isOwner)
                          const Tooltip(
                            message: 'Connections are coming soon',
                            child: OutlinedButton(
                              onPressed: null,
                              child: Text('Connect'),
                            ),
                          ),
                        if (!widget.isOwner)
                          const Tooltip(
                            message: 'Private chats are coming soon',
                            child: OutlinedButton(
                              onPressed: null,
                              child: Text('Message'),
                            ),
                          ),
                        OutlinedButton.icon(
                          onPressed: () => shareProfile(context, p),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(100, 48),
                            foregroundColor: ink,
                            side: BorderSide(
                              color: VibeColors.lilac.withValues(
                                alpha: dark ? .25 : .6,
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            visualDensity: VisualDensity.standard,
                          ),
                          icon: const Icon(Icons.north_east_rounded, size: 16),
                          label: const Text('Share'),
                        ),
                      ],
                    ),
                    if (p.socialStats != null) ...[
                      const SizedBox(height: 12),
                      _stats(p.socialStats!, ink, muted),
                    ],
                    if (widget.isOwner || p.currentVibe.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Material(
                        color: accent.withValues(alpha: dark ? .045 : .12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(
                            color: accent.withValues(alpha: .12),
                          ),
                        ),
                        child: InkWell(
                          onTap: widget.isOwner ? widget.onEdit : null,
                          borderRadius: BorderRadius.circular(14),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: accent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'CURRENT VIBE',
                                        style: TextStyle(
                                          fontSize: 9,
                                          letterSpacing: 1.4,
                                          fontWeight: FontWeight.w800,
                                          color: muted,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        p.currentVibe.isEmpty
                                            ? 'What’s your vibe?'
                                            : p.currentVibe,
                                        style: TextStyle(
                                          fontSize: 13,
                                          height: 1.5,
                                          fontWeight: FontWeight.w600,
                                          color: ink,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (widget.isOwner)
                                  Icon(
                                    Icons.north_east_rounded,
                                    size: 16,
                                    color: muted,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stats(ProfileSocialStats stats, Color ink, Color muted) => Row(
    key: const ValueKey('profile-social-stats'),
    children: [
      for (final (value, label) in [
        (stats.friends, 'Friends'),
        (stats.following, 'Following'),
        (stats.followers, 'Followers'),
      ])
        Expanded(
          child: Semantics(
            label: '$value $label',
            excludeSemantics: true,
            child: Column(
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
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(fontSize: 11, height: 1.4, color: muted),
                ),
              ],
            ),
          ),
        ),
    ],
  );
  String _shortCount(int value) {
    if (value < 1000) return '$value';
    final unit = value >= 1000000 ? 'M' : 'K';
    final number = value / (unit == 'M' ? 1000000 : 1000);
    return '${number.toStringAsFixed(number < 10 ? 1 : 0).replaceFirst(RegExp(r'\.0$'), '')}$unit';
  }

  Widget _about(BuildContext context, Profile p, Color muted) {
    final rows = <(IconData, String, bool)>[
      if (p.country != null && countryNames.containsKey(p.country))
        (Icons.public_rounded, countryNames[p.country]!, false),
      if (p.profession.isNotEmpty)
        (Icons.work_outline_rounded, p.profession, true),
      if (p.languages.isNotEmpty)
        (
          Icons.language_rounded,
          p.languages.map((v) => languageLabel(v.code)).join(' · '),
          false,
        ),
      if (p.pronouns.isNotEmpty)
        (Icons.person_outline_rounded, p.pronouns, false),
      if (p.education.isNotEmpty) (Icons.school_outlined, p.education, false),
      if (p.websiteUrl != null) (Icons.link_rounded, p.websiteUrl!, false),
    ];
    if (rows.isEmpty && !widget.isOwner) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(
          'ABOUT ME',
          muted,
          action: widget.isOwner
              ? TextButton(
                  onPressed: widget.onEdit,
                  child: const Text(
                    'EDIT',
                    style: TextStyle(fontSize: 10, letterSpacing: 1),
                  ),
                )
              : null,
        ),
        if (rows.isEmpty)
          Text(
            'A few details, a little more you.',
            style: TextStyle(fontSize: 13, height: 1.5, color: muted),
          ),
        for (final (icon, value, editable) in rows)
          if (widget.isOwner && editable)
            InkWell(
              onTap: widget.onEdit,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: _aboutRow(icon, value, muted, edit: true),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _aboutRow(icon, value, muted),
            ),
      ],
    );
  }

  Widget _aboutRow(
    IconData icon,
    String value,
    Color muted, {
    bool edit = false,
  }) => Row(
    children: [
      Icon(icon, size: 16, color: muted),
      const SizedBox(width: 10),
      Expanded(
        child: Text(value, style: const TextStyle(fontSize: 13, height: 1.5)),
      ),
      if (edit) Icon(Icons.edit_outlined, size: 13, color: muted),
    ],
  );
  Widget _sectionTitle(String title, Color muted, {Widget? action}) => Padding(
    padding: EdgeInsets.only(bottom: action == null ? 12 : 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.7,
              fontWeight: FontWeight.w800,
              color: muted,
            ),
          ),
        ),
        ?action,
      ],
    ),
  );
  Widget _interest(String name, int index, bool dark, Color accent) {
    final color = [
      accent,
      VibeColors.lilac,
      const Color(0xff9bded6),
    ][index % 3];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? .09 : .25),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        name,
        style: const TextStyle(
          fontSize: 12,
          height: 1.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _contentTab(int index, Color accent, Color muted) => Semantics(
    selected: index == tab,
    child: InkWell(
      onTap: () {
        if (index != tab) {
          HapticFeedback.selectionClick();
          setState(() => tab = index);
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
                fontWeight: index == tab ? FontWeight.w800 : FontWeight.w500,
                color: index == tab ? null : muted,
              ),
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: Duration(
                milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 200,
              ),
              width: index == tab ? 16 : 4,
              height: 3,
              decoration: BoxDecoration(
                color: index == tab ? accent : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _content(Profile p, Color accent, Color muted) {
    if (tab == 2 && p.currentVibe.isNotEmpty) {
      return Container(
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
              p.currentVibe,
              style: const TextStyle(
                fontFamily: 'SpaceGrotesk',
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (widget.isOwner)
              TextButton(
                onPressed: widget.onEdit,
                child: const Text('Change my vibe'),
              ),
          ],
        ),
      );
    }
    return Padding(
      key: ValueKey('profile-empty-$tab'),
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
                : widget.isOwner
                ? 'Set your current vibe to make this space yours.'
                : 'Check back for a little of their world.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.6, color: muted),
          ),
          if (tab == 2 && widget.isOwner)
            TextButton(
              onPressed: widget.onEdit,
              child: const Text('Set my vibe'),
            ),
        ],
      ),
    );
  }
}

/// Original code-generated monogram: a static orbital composition, not a story
/// or verification signal. Media-backed avatars need the authorized media service.
class _ProfileAvatar extends StatelessWidget {
  final Profile profile;
  final Color accent;
  final double size;
  const _ProfileAvatar({
    required this.profile,
    required this.accent,
    this.size = 112,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    label: '${profile.displayName} profile avatar',
    child: SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: accent.withValues(alpha: .45),
            width: profile.avatarFrame == 'orbit' ? 2 : .7,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: ClipOval(
            child: CustomPaint(
              painter: _IdentityAvatarPainter(accent, profile.username),
              child: Center(
                child: Text(
                  profile.displayName.trim().isEmpty
                      ? 'K'
                      : profile.displayName
                            .trim()
                            .characters
                            .first
                            .toUpperCase(),
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    fontSize: size * .36,
                    fontWeight: FontWeight.w700,
                    color: VibeColors.ink,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _IdentityAvatarPainter extends CustomPainter {
  final Color accent;
  final String identity;
  const _IdentityAvatarPainter(this.accent, this.identity);
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(accent, Colors.white, .35)!,
            accent,
            Color.lerp(accent, VibeColors.lilac, .6)!,
          ],
        ).createShader(bounds),
    );
    final seed = identity.codeUnits.fold<int>(0, (sum, c) => sum + c);
    canvas.save();
    canvas.translate(size.width * .5, size.height * .5);
    canvas.rotate((seed % 12) * math.pi / 12);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .12
      ..color = Colors.white.withValues(alpha: .16);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * .23, 0),
        width: size.width * .95,
        height: size.height * 1.4,
      ),
      line,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(-size.width * .3, 0),
        width: size.width * .7,
        height: size.height * 1.2,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = VibeColors.ink.withValues(alpha: .1),
    );
    canvas.restore();
    canvas.drawCircle(
      Offset(size.width * .77, size.height * .22),
      size.width * .035,
      Paint()..color = VibeColors.ink.withValues(alpha: .35),
    );
  }

  @override
  bool shouldRepaint(_IdentityAvatarPainter old) =>
      old.accent != accent || old.identity != identity;
}

class _ProfileStickyHeader extends SliverPersistentHeaderDelegate {
  final Profile profile;
  final ScrollController scroll;
  final Color accent;
  final bool dark, isOwner;
  final double height;
  final VoidCallback? onSettings, onOptions;
  const _ProfileStickyHeader({
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
                          _ProfileAvatar(
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
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
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
  bool shouldRebuild(_ProfileStickyHeader old) =>
      profile != old.profile ||
      accent != old.accent ||
      dark != old.dark ||
      height != old.height ||
      isOwner != old.isOwner ||
      onSettings != old.onSettings ||
      onOptions != old.onOptions;
}

class _ProfileOrbitPainter extends CustomPainter {
  final Color color;
  const _ProfileOrbitPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7;
    canvas.save();
    canvas.translate(size.width / 2, 68);
    canvas.rotate(-math.pi / 9);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: size.width * .93,
        height: 110,
      ),
      pen,
    );
    canvas.drawCircle(
      Offset(size.width * .38, -24),
      2.5,
      Paint()..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ProfileOrbitPainter old) => old.color != color;
}

class ProfileSkeleton extends StatelessWidget {
  const ProfileSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = (dark ? Colors.white : VibeColors.ink).withValues(alpha: .08);
    Widget block(double width, double height, [double radius = 10]) =>
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(radius),
          ),
        );
    return Semantics(
      label: 'Loading profile',
      child: ExcludeSemantics(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 20),
            Center(child: block(108, 108, 54)),
            const SizedBox(height: 20),
            Center(child: block(140, 22)),
            const SizedBox(height: 12),
            Center(child: block(100, 14)),
            const SizedBox(height: 24),
            block(double.infinity, 16),
            const SizedBox(height: 8),
            block(double.infinity, 16),
            const SizedBox(height: 30),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [block(100, 38), block(110, 38), block(90, 38)],
            ),
            const SizedBox(height: 30),
            block(double.infinity, 150, 20),
          ],
        ),
      ),
    );
  }
}
