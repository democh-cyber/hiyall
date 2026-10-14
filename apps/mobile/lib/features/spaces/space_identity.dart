import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import 'space_format.dart';
import 'space_parts.dart';

/// The space's header: emblem, tags, title, description, host line, schedule.
class SpaceIdentity extends StatelessWidget {
  final SocialSpace space;
  const SpaceIdentity(this.space, {super.key});
  @override
  Widget build(BuildContext context) {
    final x = space;
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
                  VibeTag(
                    spaceKindNames[x.kind] ?? x.kind,
                    color: spaceTint(x),
                  ),
                  if (timing != null)
                    SpaceMetaTag(
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
        if (x.startsAt != null) SpaceInfoLine(Icons.schedule, spaceSchedule(x)),
        if (x.location.isNotEmpty)
          SpaceInfoLine(Icons.place_outlined, x.location, selectable: true),
        if (x.rules.isNotEmpty) SpaceRulesRow(kind: x.kind, rules: x.rules),
      ],
    );
  }
}

/// Compact, expandable rules so they never dominate the page.
class SpaceRulesRow extends StatefulWidget {
  final String kind, rules;
  const SpaceRulesRow({super.key, required this.kind, required this.rules});
  @override
  State<SpaceRulesRow> createState() => _SpaceRulesRowState();
}

class _SpaceRulesRowState extends State<SpaceRulesRow> {
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
            padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 10, 10),
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
                          '${spaceKindNames[widget.kind]} rules',
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
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        28,
                        8,
                        8,
                        4,
                      ),
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

class SpaceLockedDiscussion extends StatelessWidget {
  final String kind;
  final bool pending;
  const SpaceLockedDiscussion({
    super.key,
    required this.kind,
    required this.pending,
  });
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
                  : 'Join to read the discussion and meet the people inside this ${spaceKindNames[kind]!.toLowerCase()}.',
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
