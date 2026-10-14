import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../shared/segmented.dart';
import 'space_format.dart';
import 'space_join.dart';
import 'space_parts.dart';

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
              padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CardHeader(s),
                  if (timing != null) ...[
                    const SizedBox(height: 12),
                    // One timing pill: live countdown, the start, or the end state.
                    SpaceMetaTag(
                      live || s.startsAt == null || !timing.startsWith('Starts')
                          ? timing
                          : whenLabel(s.startsAt!),
                      highlight: live,
                      icon: live ? Icons.circle : Icons.schedule,
                    ),
                  ],
                  const SizedBox(height: 12),
                  _CardFooter(
                    s,
                    busy: busy,
                    onJoin: join,
                    onOpen: widget.onOpen,
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

class _CardHeader extends StatelessWidget {
  final SocialSpace s;
  const _CardHeader(this.s);
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
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
    );
  }
}

class _CardFooter extends StatelessWidget {
  final SocialSpace s;
  final bool busy;
  final VoidCallback onJoin, onOpen;
  const _CardFooter(
    this.s, {
    required this.busy,
    required this.onJoin,
    required this.onOpen,
  });
  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return LayoutBuilder(
      builder: (context, box) {
        final meta = Text(
          spaceMeta(s),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: muted,
        );
        final action = SpaceJoinButton(
          s,
          busy: busy,
          onJoin: onJoin,
          onOpen: onOpen,
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
    );
  }
}
