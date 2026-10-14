import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/app_info.dart';
import '../core/state.dart';
import '../core/user_error.dart';
import '../shared/segmented.dart';
import 'spaces/space_card.dart';
import 'spaces/space_format.dart';
import 'spaces/spaces_actions.dart';
import 'spaces/spaces_header.dart';

export 'spaces/create_space_screen.dart' show CreateSpaceScreen;
export 'spaces/edit_space_screen.dart' show EditSpaceScreen;
export 'spaces/space_card.dart' show SpaceCard;
export 'spaces/space_format.dart'
    show spaceMeta, spaceSchedule, spaceTiming, spaceTint, whenLabel;
export 'spaces/space_join.dart' show joinSpace;
export 'spaces/space_members_screen.dart' show SpaceMembersScreen;
export 'spaces/space_parts.dart' show SpaceEmblem;
export 'spaces/space_screen.dart' show SpaceScreen;

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
    if (visibleSpaceKinds.containsKey(widget.initialKind)) {
      kind = widget.initialKind!;
    }
    if (widget.parentId != null && kind == 'community' && FeatureFlags.events) {
      kind = 'event';
    }
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
          .read(spaceActionsProvider)
          .list(
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
      if (mounted && run == generation) {
        setState(() => error = friendlyError(e));
      }
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
            ref.watch(editSpaceProvider(widget.parentId!)).asData?.value.host ==
                true);
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
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          20,
                          4,
                          20,
                          32,
                        ),
                        sliver: SliverMainAxisGroup(
                          slivers: [
                            SliverToBoxAdapter(
                              child: SpacesHeader(
                                nested: nested,
                                kind: kind,
                                mine: mine,
                                loading: loading,
                                hasItems: items.isNotEmpty,
                                canCreate: canCreate,
                                error: error,
                                onKind: (k) {
                                  kind = k;
                                  load();
                                },
                                onMine: (v) {
                                  mine = v;
                                  load();
                                },
                                onRetry: load,
                                onCreate: create,
                              ),
                            ),
                            // Cards are built lazily as they scroll into view.
                            SliverList.builder(
                              itemCount: items.length,
                              itemBuilder: (context, i) {
                                final s = items[i];
                                return EntranceFade(
                                  key: ValueKey(s.spaceId),
                                  delayMs: math.min(i, 5) * 40,
                                  child: SpaceCard(
                                    s,
                                    onOpen: () async {
                                      await context.push(
                                        '/spaces/${s.spaceId}',
                                      );
                                      if (mounted) load();
                                    },
                                  ),
                                );
                              },
                            ),
                            if (cursor != null)
                              SliverToBoxAdapter(
                                child: Center(
                                  child: TextButton(
                                    onPressed: loading
                                        ? null
                                        : () => load(more: true),
                                    child: Text(
                                      loading ? 'Loading…' : 'Load more',
                                    ),
                                  ),
                                ),
                              ),
                          ],
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
