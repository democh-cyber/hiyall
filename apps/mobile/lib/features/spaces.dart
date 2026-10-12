import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/person_avatar.dart';
import '../shared/person_link.dart';
import '../shared/segmented.dart';
import '../shared/widgets.dart';
import 'safety.dart';
import 'settings.dart' show timeAgo;

const _kinds = {
  'community': 'Communities',
  'event': 'Events',
  'moment': 'Moments',
};
const _kindNames = {
  'community': 'Community',
  'moment': 'Moment',
  'event': 'Event',
};
const _visibility = {
  'public': 'Open to all',
  'private': 'Host approval',
  'invite': 'Invite only',
};
const _states = {
  'active': 'Active',
  'pending': 'Requests',
  'invited': 'Invited',
  'banned': 'Banned',
};

(IconData, Color) _kindStyle(String kind) => switch (kind) {
  'moment' => (Icons.bolt_rounded, VibeColors.lime),
  'event' => (Icons.event_rounded, VibeColors.peach),
  _ => (Icons.groups_rounded, VibeColors.lilac),
};

/// A stable accent per space so each circle keeps its own identity.
Color spaceTint(SocialSpace s) {
  if (s.kind == 'moment') return VibeColors.lime;
  if (s.kind == 'event') return VibeColors.peach;
  const tints = [VibeColors.lilac, VibeColors.mint, VibeColors.peach];
  return tints[s.spaceId.codeUnits.fold(0, (a, b) => a + b) % tints.length];
}

String _capitalized(String v) =>
    v.isEmpty ? v : '${v[0].toUpperCase()}${v.substring(1)}';

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _day(DateTime t) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final year = t.year == DateTime.now().year ? '' : ' ${t.year}';
  return '${days[t.weekday - 1]} ${t.day} ${months[t.month - 1]}$year';
}

/// "Tonight · 20:00", "Tomorrow · 09:30" or "Sun 11 Oct · 14:00".
String whenLabel(DateTime at, [DateTime? now]) {
  final t = at.toLocal(), n = (now ?? DateTime.now()).toLocal();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day).difference(today).inDays;
  final name = day == 0
      ? (t.hour >= 17 ? 'Tonight' : 'Today')
      : day == 1
      ? 'Tomorrow'
      : _day(t);
  return '$name · ${_clock(t)}';
}

String _span(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)} min';
  if (d.inHours < 24) return '${d.inHours} h';
  final days = (d.inHours / 24).round();
  return days == 1 ? '1 day' : '$days days';
}

/// Short live state for timed spaces: "Live now · 30 min left", "Starts in 2 h".
String? spaceTiming(SocialSpace s, [DateTime? now]) {
  if (s.status == 'archived') return 'Archived';
  if (s.status == 'closed') return 'Closed';
  if (s.startsAt == null || s.endsAt == null) return null;
  final at = now ?? DateTime.now();
  if (at.isBefore(s.startsAt!)) {
    return 'Starts in ${_span(s.startsAt!.difference(at))}';
  }
  if (at.isBefore(s.endsAt!)) {
    return 'Live now · ${_span(s.endsAt!.difference(at))} left';
  }
  return 'Ended';
}

String spaceSchedule(SocialSpace s) {
  if (s.startsAt == null) return '${s.memberCount} / ${s.capacity} members';
  final start = s.startsAt!.toLocal(), end = s.endsAt!.toLocal();
  final sameDay =
      start.year == end.year &&
      start.month == end.month &&
      start.day == end.day;
  final until = sameDay ? _clock(end) : '${_day(end)}, ${_clock(end)}';
  return '${_day(start)}, ${_clock(start)} – $until (your time)\n'
      'Host zone: ${s.timezone}';
}

/// "2 / 50 members · Host approval"
String spaceMeta(SocialSpace s) =>
    '${s.memberCount} / ${s.capacity} ${s.kind == 'community' ? 'members' : 'joined'}'
    ' · ${_visibility[s.visibility] ?? s.visibility}';

/// Joins, requests or accepts an invitation, then reports the outcome.
Future<SocialSpace?> joinSpace(
  BuildContext context,
  WidgetRef ref,
  SocialSpace s, {
  String rsvp = 'going',
}) async {
  final session = ref.read(sessionProvider).asData?.value;
  if (session == null) return null;
  try {
    final next = await ref
        .read(apiProvider)
        .spaceMembership(session, s.spaceId, rsvp: rsvp);
    if (context.mounted) {
      showMessage(
        context,
        next.myState == 'pending'
            ? 'Request sent. The host will review it.'
            : 'You’re in ${s.title}.',
      );
    }
    return next;
  } catch (e) {
    if (context.mounted) showMessage(context, e.toString());
    return null;
  }
}

/// A rounded tile with the space kind's icon and colour.
class _KindBadge extends StatelessWidget {
  final String kind;
  final double size;
  const _KindBadge(this.kind, {this.size = 48});
  @override
  Widget build(BuildContext context) {
    final (icon, color) = _kindStyle(kind);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size * .32),
      ),
      child: Icon(icon, color: VibeColors.ink, size: size * .5),
    );
  }
}

/// The space's visual identity: its accent, a small orbit and the kind icon.
/// With [animate], the orbiting dot sweeps into place once on entrance.
class SpaceEmblem extends StatelessWidget {
  final SocialSpace space;
  final double size;
  final bool animate;
  const SpaceEmblem(
    this.space, {
    super.key,
    this.size = 56,
    this.animate = false,
  });
  @override
  Widget build(BuildContext context) {
    final tint = spaceTint(space);
    final icon = _kindStyle(space.kind).$1;
    Widget frame(double t) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(size * .3),
      ),
      child: CustomPaint(
        painter: _OrbitPainter(t, space.spaceId.hashCode),
        child: Center(
          child: Icon(icon, color: VibeColors.ink, size: size * .42),
        ),
      ),
    );
    if (!animate || MediaQuery.disableAnimationsOf(context)) return frame(1);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => frame(t),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  final double t;
  final int seed;
  const _OrbitPainter(this.t, this.seed);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final tilt = (seed % 7) / 7 * math.pi - math.pi / 2;
    final rx = size.width * .44, ry = size.height * .2;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(tilt * .5);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = VibeColors.ink.withValues(alpha: .28),
    );
    final angle = (seed % 360) * math.pi / 180 + math.pi * 1.4 * (1 - t);
    canvas.drawCircle(
      Offset(rx * math.cos(angle), ry * math.sin(angle)),
      size.width * .045,
      Paint()..color = VibeColors.ink,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbitPainter old) => old.t != t || old.seed != seed;
}

class _Initial extends StatelessWidget {
  final Person person;
  final double radius;
  const _Initial(this.person, {this.radius = 18});
  @override
  Widget build(BuildContext context) => PersonAvatar(
    name: person.name,
    avatarUrl: person.avatarUrl,
    userId: person.userId,
    radius: radius,
  );
}

/// A neutral metadata pill that follows the theme; [highlight] uses lime.
class _MetaTag extends StatelessWidget {
  final String text;
  final IconData? icon;
  final bool highlight;
  const _MetaTag(this.text, {this.icon, this.highlight = false});
  @override
  Widget build(BuildContext context) {
    if (highlight) return VibeTag(text, icon: icon);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              text.toUpperCase(),
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 10,
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// An icon followed by wrapping secondary text.
class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool selectable;
  const _InfoLine(this.icon, this.text, {this.selectable = false});
  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final style = TextStyle(fontSize: 14, height: 1.5, color: muted);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 19, color: muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: selectable
                ? SelectableText(text, style: style)
                : Text(text, style: style),
          ),
        ],
      ),
    );
  }
}

/// Small uppercase label that opens a section ("UPCOMING", "MEMBERS · 2").
class _Eyebrow extends StatelessWidget {
  final String text;
  const _Eyebrow(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 10),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// The join call to action for a space card or row, animated between states.
class _JoinButton extends StatelessWidget {
  final SocialSpace space;
  final VoidCallback? onJoin, onOpen;
  final bool busy;
  const _JoinButton(
    this.space, {
    required this.onJoin,
    required this.onOpen,
    this.busy = false,
  });
  @override
  Widget build(BuildContext context) {
    final s = space;
    final Widget button;
    if (s.joined) {
      button = OutlinedButton.icon(
        key: const ValueKey('joined'),
        onPressed: onOpen,
        icon: const Icon(Icons.check_rounded, size: 18),
        label: Text(
          s.myRole == 'owner'
              ? 'Hosting'
              : s.kind == 'event'
              ? (s.myRsvp == 'interested' ? 'Interested' : 'Going')
              : 'Joined',
        ),
      );
    } else if (s.myState == 'pending') {
      button = const OutlinedButton(
        key: ValueKey('pending'),
        onPressed: null,
        child: Text('Requested'),
      );
    } else if (s.status != 'open' || spaceTiming(s) == 'Ended') {
      button = const SizedBox.shrink(key: ValueKey('closed'));
    } else {
      final label = s.myState == 'invited'
          ? 'Accept invite'
          : s.visibility == 'private'
          ? 'Request to join'
          : switch (s.kind) {
              'event' => 'I’m interested',
              'moment' => 'Join Moment',
              _ => 'Join community',
            };
      button = FilledButton(
        key: const ValueKey('join'),
        onPressed: busy ? null : onJoin,
        child: Text(busy ? 'Joining…' : label),
      );
    }
    return AnimatedSwitcher(
      duration: VibeMotion.duration(context),
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween(begin: .92, end: 1.0).animate(a),
          child: child,
        ),
      ),
      child: button,
    );
  }
}

/// A community, Moment or event in a browse list.
class SpaceCard extends ConsumerStatefulWidget {
  final SocialSpace space;
  final VoidCallback onOpen;
  final ValueChanged<SocialSpace>? onChanged;
  const SpaceCard(
    this.space, {
    super.key,
    required this.onOpen,
    this.onChanged,
  });
  @override
  ConsumerState<SpaceCard> createState() => _SpaceCardState();
}

class _SpaceCardState extends ConsumerState<SpaceCard> {
  late SocialSpace s = widget.space;
  bool busy = false;
  @override
  void didUpdateWidget(SpaceCard old) {
    super.didUpdateWidget(old);
    if (old.space != widget.space) s = widget.space;
  }

  Future<void> join() async {
    setState(() => busy = true);
    final next = await joinSpace(
      context,
      ref,
      s,
      rsvp: s.kind == 'event' ? 'interested' : 'going',
    );
    if (!mounted) return;
    setState(() {
      busy = false;
      if (next != null) s = next;
    });
    if (next != null) widget.onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final timing = spaceTiming(s);
    final live = timing?.startsWith('Live') == true;
    final muted = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Pressable(
        child: Material(
          color: scheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SpaceEmblem(s, size: 52),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'SpaceGrotesk',
                                fontSize: 17,
                                height: 1.2,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (s.description.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                s.description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.45,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (timing != null) ...[
                    const SizedBox(height: 12),
                    // One timing pill: live countdown, the start, or the end state.
                    _MetaTag(
                      live || s.startsAt == null || !timing.startsWith('Starts')
                          ? timing
                          : whenLabel(s.startsAt!),
                      highlight: live,
                      icon: live ? Icons.circle : Icons.schedule,
                    ),
                  ],
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, box) {
                      final meta = Text(
                        spaceMeta(s),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      );
                      final action = _JoinButton(
                        s,
                        busy: busy,
                        onJoin: join,
                        onOpen: widget.onOpen,
                      );
                      // Small phones: the button goes under the details
                      // instead of squeezing them off the card.
                      if (box.maxWidth < 300) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [meta, const SizedBox(height: 10), action],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: meta),
                          const SizedBox(width: 10),
                          action,
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SpacesScreen extends ConsumerStatefulWidget {
  final String? parentId;
  final String? initialKind;
  const SpacesScreen({super.key, this.parentId, this.initialKind});
  @override
  ConsumerState<SpacesScreen> createState() => _SpacesState();
}

class _SpacesState extends ConsumerState<SpacesScreen> {
  String kind = 'community';
  bool mine = false, loading = false;
  String? cursor, error;
  List<SocialSpace> items = [];
  int generation = 0;
  @override
  void initState() {
    super.initState();
    if (_kinds.containsKey(widget.initialKind)) kind = widget.initialKind!;
    if (widget.parentId != null && kind == 'community') kind = 'event';
    Future.microtask(load);
  }

  Future<void> load({bool more = false}) async {
    final s = ref.read(sessionProvider).asData?.value;
    if (s == null) return;
    if (more && (loading || cursor == null)) return;
    final run = ++generation;
    setState(() {
      loading = true;
      error = null;
      if (!more) {
        items = [];
        cursor = null;
      }
    });
    try {
      final page = await ref
          .read(apiProvider)
          .spaces(
            s,
            kind,
            mine: mine,
            parentId: widget.parentId,
            cursor: more ? cursor : null,
          );
      if (!mounted ||
          run != generation ||
          ref.read(sessionProvider).asData?.value != s) {
        return;
      }
      setState(() {
        final known = items.map((x) => x.spaceId).toSet();
        items = [
          ...items,
          ...page.items.where((x) => !known.contains(x.spaceId)),
        ];
        cursor = page.nextCursor;
      });
    } catch (e) {
      if (mounted && run == generation) setState(() => error = e.toString());
    } finally {
      if (mounted && run == generation) setState(() => loading = false);
    }
  }

  Future<void> create() async {
    await context.push(
      '/spaces/new?kind=$kind${widget.parentId == null ? '' : '&parent=${widget.parentId}'}',
    );
    if (mounted) load();
  }

  @override
  Widget build(BuildContext context) {
    final signed = ref.watch(sessionProvider).asData?.value != null;
    final nested = widget.parentId != null;
    final canCreate =
        signed &&
        (!nested ||
            ref
                    .watch(_editSpaceProvider(widget.parentId!))
                    .asData
                    ?.value
                    .host ==
                true);
    final scheme = Theme.of(context).colorScheme;
    final plural = _kinds[kind]!.toLowerCase();
    return Scaffold(
      appBar: AppBar(
        systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        title: Text(nested ? 'Events & Moments' : 'Find your circle'),
        actions: [
          if (canCreate)
            IconButton(
              key: const Key('new-space'),
              tooltip: 'Create a space',
              icon: const Icon(Icons.add),
              onPressed: create,
            ),
        ],
      ),
      body: !signed
          ? const Center(child: Text('Sign in to explore shared spaces'))
          : RefreshIndicator(
              onRefresh: load,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                    children: [
                      Text(
                        nested
                            ? 'Plans inside\nthis community.'
                            : 'Small circles.\nReal conversations.',
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(
                              fontSize: 34,
                              height: 1.06,
                              letterSpacing: -1.2,
                            ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        nested ? 'Timed get-togethers hosted by this circle.' : 'Find communities around things you actually care about.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.55,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 22),
                      VibeSegmented<String>(
                        segments: [
                          for (final k in _kinds.entries)
                            if (!nested || k.key != 'community')
                              (k.key, k.value),
                        ],
                        selected: kind,
                        onChanged: (k) {
                          kind = k;
                          load();
                        },
                      ),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${mine ? 'Your' : 'All'} $plural',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          FilterChip(
                            label: const Text('Joined'),
                            selected: mine,
                            onSelected: (v) {
                              mine = v;
                              load();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (error != null)
                        FailureCard(error: error!, retry: load)
                      else if (loading && items.isEmpty)
                        const VibeLoading()
                      else if (items.isEmpty)
                        EmptyCard(
                          icon: _kindStyle(kind).$1,
                          title: mine
                              ? 'Nothing joined yet'
                              : 'A quiet corner for now',
                          description: mine
                              ? 'Spaces you join or host show up here.'
                              : 'No $plural here yet. Start something worth joining.',
                          action: canCreate
                              ? FilledButton.icon(
                                  onPressed: create,
                                  icon: const Icon(Icons.add),
                                  label: Text(
                                    'Start a ${_kindNames[kind]!.toLowerCase()}',
                                  ),
                                )
                              : null,
                        ),
                      for (final (i, s) in items.indexed)
                        EntranceFade(
                          key: ValueKey(s.spaceId),
                          delayMs: math.min(i, 5) * 40,
                          child: SpaceCard(
                            s,
                            onOpen: () async {
                              await context.push('/spaces/${s.spaceId}');
                              if (mounted) load();
                            },
                          ),
                        ),
                      if (cursor != null)
                        Center(
                          child: TextButton(
                            onPressed: loading ? null : () => load(more: true),
                            child: Text(loading ? 'Loading…' : 'Load more'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class CreateSpaceScreen extends ConsumerStatefulWidget {
  final String kind;
  final String? parentId;
  final SocialSpace? initial;
  const CreateSpaceScreen({
    super.key,
    this.kind = 'community',
    this.parentId,
    this.initial,
  });
  @override
  ConsumerState<CreateSpaceScreen> createState() => _CreateSpaceState();
}

class _CreateSpaceState extends ConsumerState<CreateSpaceScreen> {
  final title = TextEditingController(),
      description = TextEditingController(),
      rules = TextEditingController(),
      capacity = TextEditingController(text: '50'),
      zone = TextEditingController(text: 'UTC'),
      location = TextEditingController();
  String visibility = 'public';
  late DateTime start, end;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    start = DateTime.now().add(const Duration(hours: 1));
    end = start.add(const Duration(hours: 1));
    if (widget.parentId != null) visibility = 'private';
    final x = widget.initial;
    if (x != null) {
      title.text = x.title;
      description.text = x.description;
      rules.text = x.rules;
      capacity.text = '${x.capacity}';
      zone.text = x.timezone;
      location.text = x.location;
      visibility = x.visibility;
      start = x.startsAt?.toLocal() ?? start;
      end = x.endsAt?.toLocal() ?? end;
    }
  }

  @override
  void dispose() {
    for (final c in [title, description, rules, capacity, zone, location]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> pick(bool first) async {
    final initial = first ? start : end;
    final date = await showDatePicker(
      context: context,
      initialDate:
          initial.isBefore(DateTime.now().subtract(const Duration(days: 1)))
          ? DateTime.now()
          : initial,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final clock = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (clock == null || !mounted) return;
    setState(() {
      final d = DateTime(
        date.year,
        date.month,
        date.day,
        clock.hour,
        clock.minute,
      );
      if (first) {
        start = d;
        if (!end.isAfter(start)) end = start.add(const Duration(hours: 1));
      } else {
        end = d;
      }
    });
  }

  Future<void> save() async {
    final s = ref.read(sessionProvider).asData?.value;
    if (s == null) return;
    final n = int.tryParse(capacity.text);
    if (title.text.trim().isEmpty || n == null || n < 2 || n > 10000) {
      showMessage(context, 'Add a title and capacity of 2–10000.');
      return;
    }
    setState(() => busy = true);
    try {
      final body = <String, dynamic>{
        'kind': widget.kind,
        'title': title.text.trim(),
        'description': description.text.trim(),
        'rules': rules.text.trim(),
        'visibility': visibility,
        'capacity': n,
        'timezone': zone.text.trim(),
        'location': location.text.trim(),
        if (widget.parentId != null) 'parentId': widget.parentId,
        if (widget.kind != 'community')
          'startsAt': start.toUtc().toIso8601String(),
        if (widget.kind != 'community') 'endsAt': end.toUtc().toIso8601String(),
      };
      final a = ref.read(apiProvider);
      final x = widget.initial == null
          ? await a.createSpace(s, body)
          : await a.updateSpace(s, widget.initial!.spaceId, body);
      if (mounted) {
        if (widget.initial != null) {
          context.pop();
        } else {
          context.replace('/spaces/${x.spaceId}');
        }
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _section(String title, [String? hint]) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(
            hint,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );

  Widget _when(String label, DateTime at, bool first) => Expanded(
    child: OutlinedButton(
      onPressed: busy ? null : () => pick(first),
      style: OutlinedButton.styleFrom(
        alignment: AlignmentDirectional.centerStart,
        padding: const EdgeInsets.all(14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VibeRadius.input),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(_day(at), style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(_clock(at)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final name = _kindNames[widget.kind] ?? 'Space';
    const gap = SizedBox(height: 14);
    return Scaffold(
      appBar: AppBar(
        systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        title: Text(
          '${widget.initial == null ? 'New' : 'Edit'} ${name.toLowerCase()}',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Row(
            children: [
              _KindBadge(widget.kind, size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  widget.kind == 'community'
                      ? 'A home for people who share a thing.'
                      : widget.kind == 'moment'
                      ? 'A short, timed get-together that ends on schedule.'
                      : 'A plan to meet, online or in person.',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ],
          ),
          _section('Basics'),
          TextField(
            key: const Key('space-title'),
            controller: title,
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Give it a name',
            ),
          ),
          gap,
          TextField(
            controller: description,
            maxLength: 2000,
            maxLines: 4,
            minLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'About',
              hintText: 'What brings people here?',
              alignLabelWithHint: true,
            ),
          ),
          gap,
          TextField(
            controller: rules,
            maxLength: 2000,
            maxLines: 3,
            minLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Rules',
              hintText: 'Rules for your circle',
              alignLabelWithHint: true,
            ),
          ),
          _section(
            'Who can join',
            widget.initial == null ? null : 'Set when the space is created.',
          ),
          DropdownButtonFormField<String>(
            initialValue: visibility,
            decoration: const InputDecoration(labelText: 'Access'),
            items: const [
              DropdownMenuItem(
                value: 'public',
                child: Text('Public · join instantly'),
              ),
              DropdownMenuItem(
                value: 'private',
                child: Text('Private · host approves'),
              ),
              DropdownMenuItem(value: 'invite', child: Text('Invite only')),
            ],
            onChanged: busy || widget.initial != null
                ? null
                : (v) => setState(() => visibility = v!),
          ),
          gap,
          TextField(
            controller: capacity,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Capacity',
              helperText: 'Includes you as the host · 2 to 10000',
            ),
          ),
          if (widget.kind != 'community') ...[
            _section(
              'When',
              'Pick times in your device’s local time. The host zone is saved alongside UTC.',
            ),
            Row(
              children: [
                _when('Starts', start, true),
                const SizedBox(width: 12),
                _when('Ends', end, false),
              ],
            ),
            gap,
            TextField(
              controller: zone,
              decoration: const InputDecoration(
                labelText: 'Host time zone',
                helperText: 'IANA name, e.g. Asia/Kolkata',
              ),
            ),
            if (widget.kind == 'event') ...[
              gap,
              TextField(
                controller: location,
                maxLength: 240,
                decoration: const InputDecoration(
                  labelText: 'Where',
                  hintText: 'Online link or meeting place',
                ),
              ),
            ],
          ],
          const SizedBox(height: 24),
          VibePanel(
            color: VibeColors.lilac,
            padding: const EdgeInsets.all(16),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, color: VibeColors.ink),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Discussion boards are shared content readable by members and the service. Use encrypted chat for private conversations.',
                    style: TextStyle(color: VibeColors.ink, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('publish-space'),
            onPressed: busy ? null : save,
            child: Text(
              busy
                  ? 'Saving…'
                  : widget.initial == null
                  ? 'Create ${name.toLowerCase()}'
                  : 'Save changes',
            ),
          ),
        ],
      ),
    );
  }
}

class SpaceScreen extends ConsumerStatefulWidget {
  final String id;
  const SpaceScreen({super.key, required this.id});
  @override
  ConsumerState<SpaceScreen> createState() => _SpaceState();
}

class _SpaceState extends ConsumerState<SpaceScreen>
    with WidgetsBindingObserver {
  SocialSpace? space;
  List<SpaceEntry> entries = [];
  String? cursor, error;
  bool busy = false, loading = false;
  final text = TextEditingController();
  Timer? timer;
  int generation = 0;
  String tab = 'discussion';

  // Events and members load the first time their tab opens.
  List<SocialSpace>? plans;
  List<SpaceMember>? members;
  String? membersCursor, tabError;

  /// The newest request per tab. A tab switch never waits on, or is dropped
  /// because of, another tab's request, and only the latest one is applied.
  final _tabRequests = <String, int>{};
  int _tabRequest = 0;
  bool get tabLoading => _tabRequests.containsKey(tab);

  // The app bar names the space once its big title has scrolled away.
  final scroll = ScrollController();
  final tabsKey = GlobalKey();
  bool titled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scroll.addListener(() {
      final next = scroll.offset > 150;
      if (next != titled) setState(() => titled = next);
    });
    Future.microtask(load);
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        reloadQuietly();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) reloadQuietly();
  }

  /// A background re-read of the first page. Skipped while the person is
  /// acting, or once they've loaded older entries a reload would discard.
  void reloadQuietly() {
    if (mounted && !busy && !loading && cursorDepth == 0) {
      load(background: true);
    }
  }

  /// Pages loaded beyond the first.
  int cursorDepth = 0;

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    scroll.dispose();
    text.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false, bool background = false}) async {
    if (loading) return;
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return;
    final run = ++generation;
    setState(() => loading = true);
    try {
      final api = ref.read(apiProvider);
      final x = await api.space(session, widget.id);
      final page = x.joined
          ? await api.spaceEntries(session, widget.id, more ? cursor : null)
          : null;
      if (!mounted ||
          run != generation ||
          ref.read(sessionProvider).asData?.value != session) {
        return;
      }
      setState(() {
        space = x;
        entries = more ? [...entries, ...?page?.items] : page?.items ?? [];
        cursor = page?.nextCursor;
        cursorDepth = more ? cursorDepth + 1 : 0;
        error = null;
        if (!x.joined) {
          plans = members = null;
          tab = 'discussion';
        }
      });
    } catch (e) {
      if (!mounted || run != generation) return;
      final status = e is ApiFailure ? e.status : null;
      // Access really ended, or there's nothing to keep: show the failure.
      // A blip while the space is already on screen leaves it in place.
      if (status == 403 || status == 404 || space == null) {
        setState(() {
          error = e.toString();
          space = null;
          entries = [];
          cursor = null;
          cursorDepth = 0;
          plans = members = null;
        });
      } else if (!background) {
        showMessage(context, e.toString());
      }
    } finally {
      if (mounted && run == generation) setState(() => loading = false);
    }
  }

  Future<void> loadTab({bool more = false}) async {
    final session = ref.read(sessionProvider).asData?.value;
    final x = space;
    final which = tab;
    if (session == null || x == null) return;
    if (more && _tabRequests.containsKey(which)) return;
    final run = ++_tabRequest;
    setState(() {
      _tabRequests[which] = run;
      tabError = null;
    });
    bool latest() => mounted && _tabRequests[which] == run;
    try {
      final api = ref.read(apiProvider);
      if (which == 'events') {
        final pages = await Future.wait([
          api.spaces(session, 'event', parentId: x.spaceId),
          api.spaces(session, 'moment', parentId: x.spaceId),
        ]);
        final all = [for (final p in pages) ...p.items]
          ..sort(
            (a, b) => (a.startsAt ?? a.createdAt).compareTo(
              b.startsAt ?? b.createdAt,
            ),
          );
        if (latest()) setState(() => plans = all);
      } else if (which == 'members') {
        final page = await api.spaceMembers(
          session,
          x.spaceId,
          cursor: more ? membersCursor : null,
        );
        if (latest()) {
          setState(() {
            members = more ? [...?members, ...page.items] : page.items;
            membersCursor = page.nextCursor;
          });
        }
      }
    } catch (e) {
      if (latest() && tab == which) setState(() => tabError = e.toString());
    } finally {
      if (latest()) setState(() => _tabRequests.remove(which));
    }
  }

  Future<void> refresh() async {
    await load();
    if (!mounted) return;
    plans = members = null;
    if (tab != 'discussion') await loadTab();
  }

  void openTab(String next) {
    setState(() {
      tab = next;
      tabError = null;
    });
    if ((next == 'events' && plans == null) ||
        (next == 'members' && members == null)) {
      loadTab();
    }
  }

  Future<void> act(Future<void> Function(ApiClient, Session) work) async {
    if (busy || loading) return;
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return;
    setState(() => busy = true);
    try {
      await work(ref.read(apiProvider), session);
      if (mounted) await load();
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> leave(SocialSpace x) async {
    final name = _kindNames[x.kind]!.toLowerCase();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Leave this $name?'),
        content: Text(
          x.kind == 'community'
              ? 'You’ll lose access to its discussion and upcoming events.'
              : 'You’ll lose access to its discussion.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await act((a, s) async {
      await a.spaceMembership(s, x.spaceId, join: false);
      if (mounted) context.pop();
    });
  }

  void showRules(SocialSpace x) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_kindNames[x.kind]} rules',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            Text(x.rules, style: const TextStyle(fontSize: 15, height: 1.55)),
          ],
        ),
      ),
    ),
  );

  List<PopupMenuEntry<String>> menu(SocialSpace x) {
    final me = ref.read(sessionProvider).asData?.value?.userId;
    PopupMenuItem<String> item(String value, IconData icon, String label) =>
        PopupMenuItem(
          value: value,
          child: Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 12),
              Flexible(child: Text(label)),
            ],
          ),
        );
    return [
      item('refresh', Icons.refresh, 'Refresh'),
      if (x.rules.isNotEmpty)
        item(
          'rules',
          Icons.info_outline_rounded,
          '${_kindNames[x.kind]} rules',
        ),
      if (x.host) ...[
        const PopupMenuDivider(),
        item('edit', Icons.edit_outlined, 'Edit details & schedule'),
        for (final status in ['open', 'closed', 'archived'])
          if (status != x.status)
            item(
              'status:$status',
              status == 'open'
                  ? Icons.lock_open_rounded
                  : status == 'closed'
                  ? Icons.lock_outline_rounded
                  : Icons.archive_outlined,
              status == 'open'
                  ? 'Reopen'
                  : status == 'closed'
                  ? 'Close to new people'
                  : 'Archive',
            ),
      ],
      if (x.owner.userId != me || (x.joined && x.myRole != 'owner'))
        const PopupMenuDivider(),
      if (x.owner.userId != me)
        item(
          'report',
          Icons.flag_outlined,
          'Report ${_kindNames[x.kind]!.toLowerCase()}',
        ),
      if (x.joined && x.myRole != 'owner')
        item('leave', Icons.logout_rounded, 'Leave'),
    ];
  }

  /// Shows the saved details as soon as the editor closes.
  Future<void> edit(SocialSpace x) async {
    await context.push('/spaces/${x.spaceId}/edit');
    if (mounted) await refresh();
  }

  void onMenu(SocialSpace x, String v) {
    if (v == 'refresh') {
      refresh();
    } else if (v == 'rules') {
      showRules(x);
    } else if (v == 'edit') {
      edit(x);
    } else if (v.startsWith('status:')) {
      final status = v.substring(7);
      act((a, s) async {
        await a.spaceStatus(s, x.spaceId, status);
      });
    } else if (v == 'report') {
      showReportSheet(
        context,
        ref,
        targetType: 'space',
        targetId: x.spaceId,
        name: x.title,
      );
    } else if (v == 'leave') {
      leave(x);
    }
  }

  Widget _identity(SocialSpace x) {
    final scheme = Theme.of(context).colorScheme;
    final timing = spaceTiming(x);
    final live = timing?.startsWith('Live') == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SpaceEmblem(x, size: 76, animate: true),
            const SizedBox(width: 14),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  VibeTag(_kindNames[x.kind] ?? x.kind, color: spaceTint(x)),
                  if (timing != null)
                    _MetaTag(
                      timing,
                      highlight: live,
                      icon: live ? Icons.circle : Icons.schedule,
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          x.title,
          style: Theme.of(context).textTheme.headlineLarge
              ?.copyWith(fontSize: 30, height: 1.1, letterSpacing: -.8),
        ),
        if (x.description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            x.description,
            style: TextStyle(
              fontSize: 15,
              height: 1.55,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          '${spaceMeta(x)} · hosted by ${x.owner.name}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        if (x.startsAt != null) _InfoLine(Icons.schedule, spaceSchedule(x)),
        if (x.location.isNotEmpty)
          _InfoLine(Icons.place_outlined, x.location, selectable: true),
        if (x.rules.isNotEmpty) _RulesRow(kind: x.kind, rules: x.rules),
      ],
    );
  }

  Widget _actions(SocialSpace x) {
    if (!x.joined) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          key: const Key('join-space'),
          onPressed:
              busy || loading || x.myState == 'pending' || x.status != 'open'
              ? null
              : () => act((a, s) async {
                  await a.spaceMembership(s, x.spaceId);
                }),
          icon: Icon(
            x.myState == 'pending'
                ? Icons.hourglass_top_rounded
                : x.kind == 'event'
                ? Icons.event_available_rounded
                : Icons.add_rounded,
          ),
          label: Text(
            x.status != 'open'
                ? 'Not accepting new people'
                : x.myState == 'pending'
                ? 'Waiting for approval'
                : x.myState == 'invited'
                ? 'Accept invitation'
                : x.visibility == 'private'
                ? 'Request to join'
                : x.kind == 'event'
                ? 'RSVP · Going'
                : x.kind == 'moment'
                ? 'Join this Moment'
                : 'Join community',
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => showMessage(
                  context,
                  x.myRole == 'owner'
                      ? 'You host this ${_kindNames[x.kind]!.toLowerCase()}.'
                      : 'You’re a member. Leave from the ⋯ menu.',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: VibeColors.mint,
                  foregroundColor: VibeColors.ink,
                ),
                icon: const Icon(Icons.check_rounded),
                label: Text(x.myRole == 'owner' ? 'Hosting' : 'Joined'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  openTab('members');
                  final target = tabsKey.currentContext;
                  if (target != null) {
                    Scrollable.ensureVisible(
                      target,
                      duration: VibeMotion.duration(context),
                      curve: Curves.easeOutCubic,
                    );
                  }
                },
                icon: const Icon(Icons.people_outline_rounded),
                label: const Text('Members'),
              ),
            ),
          ],
        ),
        if (x.kind == 'event') ...[
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'going',
                icon: Icon(Icons.check_rounded),
                label: Text('Going'),
              ),
              ButtonSegment(
                value: 'interested',
                icon: Icon(Icons.star_outline_rounded),
                label: Text('Interested'),
              ),
            ],
            selected: {x.myRsvp.isEmpty ? 'going' : x.myRsvp},
            showSelectedIcon: false,
            onSelectionChanged: busy
                ? null
                : (v) => act((a, s) async {
                    await a.spaceMembership(s, x.spaceId, rsvp: v.first);
                  }),
          ),
        ],
      ],
    );
  }

  Widget _discussion(SocialSpace x) {
    final muted = TextStyle(
      fontSize: 13,
      height: 1.5,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Column(
      key: const ValueKey('discussion'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Shared discussion',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text('Talk, share and meet people inside this circle.', style: muted),
        const SizedBox(height: 16),
        if (x.canDiscuss) ...[
          TextField(
            key: const Key('space-entry'),
            controller: text,
            maxLength: 2000,
            maxLines: 4,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            buildCounter:
                (_, {required currentLength, required isFocused, maxLength}) =>
                    currentLength < 1800
                    ? null
                    : Text('$currentLength / $maxLength'),
            decoration: InputDecoration(
              hintText: 'What’s on your mind?',
              suffixIcon: Padding(
                padding: const EdgeInsets.all(6),
                child: IconButton.filled(
                  key: const Key('send-space-entry'),
                  tooltip: 'Post',
                  onPressed: busy || loading
                      ? null
                      : () => act((a, s) async {
                          await a.addSpaceEntry(s, x.spaceId, text.text);
                          text.clear();
                        }),
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.visibility_outlined, size: 14, color: muted.color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Seen by members and Hiyall. Keep private talk in encrypted chat.',
                  style: muted.copyWith(fontSize: 12),
                ),
              ),
            ],
          ),
        ] else
          _InfoLine(
            Icons.lock_clock_outlined,
            'This discussion is read-only outside its scheduled time or while closed.',
          ),
        const SizedBox(height: 18),
        if (entries.isEmpty && !loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                x.canDiscuss
                    ? 'Nothing here yet. Start the conversation.'
                    : 'No one shared anything while this was open.',
                style: muted,
              ),
            ),
          ),
        for (final e in entries) _entry(x, e),
        if (cursor != null)
          Center(
            child: TextButton(
              onPressed: loading ? null : () => load(more: true),
              child: const Text('Older thoughts'),
            ),
          ),
      ],
    );
  }

  Widget _entry(SocialSpace x, SpaceEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final me = ref.read(sessionProvider).asData?.value?.userId;
    final mine = e.author.userId == me;
    return EntranceFade(
      key: ValueKey(e.entryId),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => openPerson(context, e.author.userId),
              child: _Initial(e.author),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: InkWell(
                            onTap: () => openPerson(context, e.author.userId),
                            child: Text(
                              e.author.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (e.canDelete || !mine)
                        SizedBox(
                          width: 32,
                          height: 28,
                          child: PopupMenuButton<String>(
                            tooltip: 'More',
                            padding: EdgeInsets.zero,
                            iconSize: 18,
                            icon: Icon(
                              Icons.more_vert,
                              color: scheme.onSurfaceVariant,
                            ),
                            onSelected: (v) {
                              if (v == 'delete') {
                                act(
                                  (a, s) => a.deleteSpaceEntry(
                                    s,
                                    x.spaceId,
                                    e.entryId,
                                  ),
                                );
                              } else {
                                showReportSheet(
                                  context,
                                  ref,
                                  targetType: 'space_entry',
                                  targetId: e.entryId,
                                  name: e.author.name,
                                );
                              }
                            },
                            itemBuilder: (_) => [
                              if (e.canDelete)
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete'),
                                ),
                              if (!mine)
                                const PopupMenuItem(
                                  value: 'report',
                                  child: Text('Report'),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    e.body,
                    style: const TextStyle(fontSize: 15, height: 1.5),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    timeAgo(e.createdAt),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabState({required String empty}) {
    if (tabError != null) {
      return FailureCard(error: tabError!, retry: loadTab);
    }
    if (tabLoading) return const VibeLoading();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Text(
          empty,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _events(SocialSpace x) {
    final now = DateTime.now();
    final list = plans ?? const <SocialSpace>[];
    final live = [
      for (final p in list)
        if (spaceTiming(p, now)?.startsWith('Live') == true) p,
    ];
    final upcoming = [
      for (final p in list)
        if (p.startsAt != null && p.startsAt!.isAfter(now)) p,
    ];
    final past = [
      for (final p in list)
        if (!live.contains(p) && !upcoming.contains(p)) p,
    ].reversed.toList();
    Widget group(String title, List<SocialSpace> items) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Eyebrow(title),
        for (final p in items)
          _PlanRow(
            p,
            onOpen: () async {
              await context.push('/spaces/${p.spaceId}');
              if (mounted) {
                plans = null;
                loadTab();
              }
            },
          ),
        const SizedBox(height: 8),
      ],
    );
    return Column(
      key: const ValueKey('events'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (x.host)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final kind in ['event', 'moment'])
                  ActionChip(
                    avatar: Icon(_kindStyle(kind).$1, size: 18),
                    label: Text('New ${_kindNames[kind]!.toLowerCase()}'),
                    onPressed: () async {
                      await context.push(
                        '/spaces/new?kind=$kind&parent=${x.spaceId}',
                      );
                      if (mounted) {
                        plans = null;
                        loadTab();
                      }
                    },
                  ),
              ],
            ),
          ),
        if (plans == null || list.isEmpty)
          _tabState(
            empty: x.host
                ? 'No events or Moments yet. Plan the first one.'
                : 'No events or Moments planned yet.',
          )
        else ...[
          if (live.isNotEmpty) group('Happening now', live),
          if (upcoming.isNotEmpty) group('Upcoming', upcoming),
          if (past.isNotEmpty) group('Earlier', past),
          if (tabError != null) FailureCard(error: tabError!, retry: loadTab),
        ],
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () => context.push('/spaces?parent=${x.spaceId}'),
            icon: const Icon(Icons.arrow_forward_rounded, size: 18),
            label: const Text('Browse all'),
          ),
        ),
      ],
    );
  }

  Widget _members(SocialSpace x) {
    final scheme = Theme.of(context).colorScheme;
    final list = members ?? const <SpaceMember>[];
    return Column(
      key: const ValueKey('members'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _Eyebrow('Members · ${x.memberCount}')),
            if (x.moderate)
              TextButton(
                onPressed: () async {
                  await context.push('/spaces/${x.spaceId}/members');
                  if (mounted) refresh();
                },
                child: const Text('Manage'),
              ),
          ],
        ),
        if (members == null || list.isEmpty)
          _tabState(empty: 'No members to show yet.')
        else ...[
          for (final m in list)
            InkWell(
              borderRadius: BorderRadius.circular(VibeRadius.small),
              onTap: () => openPerson(context, m.user.userId),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    _Initial(m.user, radius: 22),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.user.name,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          Text(
                            [
                              if (m.role == 'owner')
                                'Host'
                              else if (m.role != 'member')
                                _capitalized(m.role),
                              if (m.user.username.isNotEmpty)
                                '@${m.user.username}',
                              if (x.kind == 'event' && m.rsvp.isNotEmpty)
                                _capitalized(m.rsvp),
                            ].join(' · '),
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          if (membersCursor != null)
            TextButton(
              onPressed: tabLoading ? null : () => loadTab(more: true),
              child: const Text('Show more members'),
            ),
          if (tabError != null) FailureCard(error: tabError!, retry: loadTab),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final x = ref.watch(sessionProvider).asData?.value == null ? null : space;
    final tabs = x == null
        ? const <(String, String)>[]
        : [
            ('discussion', 'Discussion'),
            if (x.kind == 'community') ('events', 'Events'),
            ('members', 'Members'),
          ];
    return Scaffold(
      appBar: AppBar(
        systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        title: AnimatedOpacity(
          opacity: x == null || titled ? 1 : 0,
          duration: VibeMotion.duration(context),
          child: Text(
            x?.title ?? 'Your circle',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        actions: [
          if (x == null)
            IconButton(
              tooltip: 'Refresh',
              onPressed: loading ? null : load,
              icon: const Icon(Icons.refresh),
            )
          else
            PopupMenuButton<String>(
              key: const Key('space-menu'),
              tooltip: 'More options',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (v) => onMenu(x, v),
              itemBuilder: (_) => menu(x),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                if (error != null) FailureCard(error: error!, retry: load),
                if (x == null && loading && error == null) const VibeLoading(),
                if (x != null) ...[
                  EntranceFade(child: _identity(x)),
                  const SizedBox(height: 20),
                  EntranceFade(delayMs: 60, child: _actions(x)),
                  const SizedBox(height: 28),
                  if (x.joined) ...[
                    VibeSegmented<String>(
                      key: tabsKey,
                      segments: tabs,
                      selected: tab,
                      onChanged: openTab,
                      keyFor: (t) => Key('space-tab-$t'),
                    ),
                    const SizedBox(height: 24),
                    AnimatedSwitcher(
                      duration: VibeMotion.duration(context),
                      transitionBuilder: (child, a) =>
                          FadeTransition(opacity: a, child: child),
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.topCenter,
                        children: [...previous, ?current],
                      ),
                      child: switch (tab) {
                        'events' => _events(x),
                        'members' => _members(x),
                        _ => _discussion(x),
                      },
                    ),
                  ] else
                    _LockedDiscussion(
                      kind: x.kind,
                      pending: x.myState == 'pending',
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact, expandable rules so they never dominate the page.
class _RulesRow extends StatefulWidget {
  final String kind, rules;
  const _RulesRow({required this.kind, required this.rules});
  @override
  State<_RulesRow> createState() => _RulesRowState();
}

class _RulesRowState extends State<_RulesRow> {
  bool open = false;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VibeRadius.input),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => open = !open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: AnimatedSize(
              duration: VibeMotion.duration(context),
              alignment: Alignment.topCenter,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${_kindNames[widget.kind]} rules',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      AnimatedRotation(
                        turns: open ? .5 : 0,
                        duration: VibeMotion.duration(context),
                        child: Icon(
                          Icons.expand_more_rounded,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  if (open)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(28, 8, 8, 4),
                      child: Text(
                        widget.rules,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LockedDiscussion extends StatelessWidget {
  final String kind;
  final bool pending;
  const _LockedDiscussion({required this.kind, required this.pending});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(VibeRadius.surface - 6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.forum_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              pending
                  ? 'Once the host approves you, the discussion opens here.'
                  : 'Join to read the discussion and meet the people inside this ${_kindNames[kind]!.toLowerCase()}.',
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// An event or Moment inside a community: when, what and who's in.
class _PlanRow extends ConsumerStatefulWidget {
  final SocialSpace space;
  final VoidCallback onOpen;
  const _PlanRow(this.space, {required this.onOpen});
  @override
  ConsumerState<_PlanRow> createState() => _PlanRowState();
}

class _PlanRowState extends ConsumerState<_PlanRow> {
  late SocialSpace s = widget.space;
  bool busy = false;
  @override
  void didUpdateWidget(_PlanRow old) {
    super.didUpdateWidget(old);
    if (old.space != widget.space) s = widget.space;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final timing = spaceTiming(s);
    final live = timing?.startsWith('Live') == true;
    return Pressable(
      child: InkWell(
        borderRadius: BorderRadius.circular(VibeRadius.control),
        onTap: widget.onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SpaceEmblem(s, size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      live
                          ? timing!
                          : s.startsAt == null
                          ? (timing ?? '')
                          : whenLabel(s.startsAt!),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: live ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.title,
                      style: const TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${s.memberCount} ${s.kind == 'event' ? 'going or interested' : 'joined'}',
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _JoinButton(
                      s,
                      busy: busy,
                      onOpen: widget.onOpen,
                      onJoin: () async {
                        setState(() => busy = true);
                        final next = await joinSpace(
                          context,
                          ref,
                          s,
                          rsvp: s.kind == 'event' ? 'interested' : 'going',
                        );
                        if (!mounted) return;
                        setState(() {
                          busy = false;
                          if (next != null) s = next;
                        });
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SpaceMembersScreen extends ConsumerStatefulWidget {
  final String id;

  /// Opens on this list (for example `pending` from a join request).
  final String? initialState;
  const SpaceMembersScreen({super.key, required this.id, this.initialState});
  @override
  ConsumerState<SpaceMembersScreen> createState() => _MembersState();
}

class _MembersState extends ConsumerState<SpaceMembersScreen> {
  SocialSpace? space;
  List<SpaceMember> members = [];
  String state = 'active';
  String? cursor, error;
  bool busy = false;
  final invite = TextEditingController();
  @override
  void initState() {
    super.initState();
    if (_states.containsKey(widget.initialState)) {
      state = widget.initialState!;
    }
    Future.microtask(load);
  }

  @override
  void dispose() {
    invite.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (busy) return;
    final s = ref.read(sessionProvider).asData?.value;
    if (s == null) return;
    setState(() => busy = true);
    try {
      final a = ref.read(apiProvider);
      final x = await a.space(s, widget.id);
      final p = await a.spaceMembers(
        s,
        widget.id,
        state: state,
        cursor: more ? cursor : null,
      );
      if (mounted && ref.read(sessionProvider).asData?.value == s) {
        setState(() {
          space = x;
          members = more ? [...members, ...p.items] : p.items;
          cursor = p.nextCursor;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          members = [];
          space = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> action(String user, String action) async {
    if (busy) return;
    final s = ref.read(sessionProvider).asData?.value;
    if (s == null) return;
    setState(() => busy = true);
    try {
      if (action == 'invite') {
        await ref.read(apiProvider).inviteSpaceUser(s, widget.id, user);
      } else {
        await ref
            .read(apiProvider)
            .spaceMemberAction(s, widget.id, user, action);
      }
      if (mounted) {
        setState(() => busy = false);
        await load();
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(sessionProvider).asData?.value == null) {
      return const Scaffold(
        body: Center(child: Text('Sign in to view participants')),
      );
    }
    final x = space;
    return Scaffold(
      appBar: AppBar(
        systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        title: const Text('Participants'),
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (x != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    _KindBadge(x.kind, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            x.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            '${x.memberCount} of ${x.capacity} spots taken',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (x?.host == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: invite,
                        textInputAction: TextInputAction.send,
                        onSubmitted: busy
                            ? null
                            : (v) => action(v.trim(), 'invite'),
                        decoration: const InputDecoration(
                          labelText: 'Invite someone',
                          hintText: '@username',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Invite',
                      onPressed: busy
                          ? null
                          : () => action(invite.text.trim(), 'invite'),
                      icon: const Icon(Icons.person_add_outlined),
                    ),
                  ],
                ),
              ),
            if (x?.moderate == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final k in _states.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            showCheckmark: false,
                            label: Text(k.value),
                            selected: k.key == state,
                            onSelected: busy
                                ? null
                                : (_) {
                                    state = k.key;
                                    load();
                                  },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (error != null) FailureCard(error: error!, retry: load),
            if (busy && members.isEmpty) const VibeLoading(),
            if (!busy && members.isEmpty && error == null)
              EmptyCard(
                icon: Icons.people_outline_rounded,
                title: 'No one here',
                description: state == 'active'
                    ? 'No participants in this list.'
                    : 'No ${_states[state]!.toLowerCase()} right now.',
              ),
            for (final m in members)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: _Initial(m.user, radius: 22),
                title: Text(
                  m.user.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  [
                    if (m.user.username.isNotEmpty) '@${m.user.username}',
                    if (x?.kind == 'event' && m.rsvp.isNotEmpty)
                      _capitalized(m.rsvp),
                  ].join(' · '),
                ),
                onTap: () => openPerson(context, m.user.userId),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (m.role != 'member')
                      VibeTag(
                        m.role == 'owner' ? 'Host' : m.role,
                        color: m.role == 'owner'
                            ? VibeColors.lime
                            : VibeColors.lilac,
                      ),
                    if (x?.moderate == true &&
                        m.role != 'owner' &&
                        m.user.userId !=
                            ref.read(sessionProvider).asData?.value?.userId)
                      PopupMenuButton<String>(
                        tooltip: 'Manage',
                        onSelected: (v) => action(m.user.userId, v),
                        itemBuilder: (_) => [
                          if (m.state == 'pending')
                            const PopupMenuItem(
                              value: 'approve',
                              child: Text('Approve'),
                            ),
                          if (m.state == 'banned')
                            const PopupMenuItem(
                              value: 'unban',
                              child: Text('Unban'),
                            )
                          else ...[
                            const PopupMenuItem(
                              value: 'remove',
                              child: Text('Remove'),
                            ),
                            const PopupMenuItem(
                              value: 'ban',
                              child: Text('Ban'),
                            ),
                          ],
                          if (x?.host == true && m.state == 'active') ...[
                            const PopupMenuItem(
                              value: 'moderator',
                              child: Text('Make moderator'),
                            ),
                            const PopupMenuItem(
                              value: 'member',
                              child: Text('Make member'),
                            ),
                            if (x?.myRole == 'owner')
                              const PopupMenuItem(
                                value: 'admin',
                                child: Text('Make admin'),
                              ),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            if (cursor != null)
              Center(
                child: TextButton(
                  onPressed: busy ? null : () => load(more: true),
                  child: const Text('Load more'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final _editSpaceProvider = FutureProvider.autoDispose
    .family<SocialSpace, String>((ref, id) async {
      final s = ref.watch(sessionProvider).asData?.value;
      if (s == null) throw const ApiFailure('Sign in to edit a space');
      return ref.watch(apiProvider).space(s, id);
    });

class EditSpaceScreen extends ConsumerWidget {
  final String id;
  const EditSpaceScreen({super.key, required this.id});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(_editSpaceProvider(id))
      .when(
        data: (x) => x.host
            ? CreateSpaceScreen(kind: x.kind, parentId: x.parentId, initial: x)
            : const Scaffold(
                body: Center(child: Text('Only hosts can edit this space')),
              ),
        loading: () => const Scaffold(body: VibeLoading()),
        error: (e, _) => Scaffold(
          appBar: AppBar(
            systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark,
            title: const Text('Edit space'),
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              FailureCard(
                error: e,
                retry: () => ref.invalidate(_editSpaceProvider(id)),
              ),
            ],
          ),
        ),
      );
}
