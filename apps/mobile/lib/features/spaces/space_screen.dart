import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/app_info.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../../core/user_error.dart';
import '../../shared/segmented.dart';
import '../../shared/widgets.dart';
import '../safety.dart';
import 'space_action_bar.dart';
import 'space_discussion.dart';
import 'space_events_tab.dart';
import 'space_identity.dart';
import 'space_members_tab.dart';
import 'space_menu.dart';
import 'space_tab_fade.dart';
import 'spaces_actions.dart';

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

  /// True once the person has switched tabs: later tab bodies fade in.
  bool fadeTabs = false;

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
      final api = ref.read(spaceActionsProvider);
      final x = await api.get(session, widget.id);
      final page = x.joined
          ? await api.entries(session, widget.id, more ? cursor : null)
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
          fadeTabs = false;
        }
      });
    } catch (e) {
      if (!mounted || run != generation) return;
      final status = e is ApiFailure ? e.status : null;
      // Access really ended, or there's nothing to keep: show the failure.
      // A blip while the space is already on screen leaves it in place.
      if (status == 403 || status == 404 || space == null) {
        setState(() {
          error = friendlyError(e);
          space = null;
          entries = [];
          cursor = null;
          cursorDepth = 0;
          plans = members = null;
        });
      } else if (!background) {
        showFailure(context, e);
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
      final api = ref.read(spaceActionsProvider);
      if (which == 'events') {
        final pages = await Future.wait([
          api.list(session, 'event', parentId: x.spaceId),
          api.list(session, 'moment', parentId: x.spaceId),
        ]);
        final all = [for (final p in pages) ...p.items]
          ..sort(
            (a, b) => (a.startsAt ?? a.createdAt).compareTo(
              b.startsAt ?? b.createdAt,
            ),
          );
        if (latest()) setState(() => plans = all);
      } else if (which == 'members') {
        final page = await api.members(
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
      if (latest() && tab == which) setState(() => tabError = friendlyError(e));
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
      if (next != tab) fadeTabs = true;
      tab = next;
      tabError = null;
    });
    if ((next == 'events' && plans == null) ||
        (next == 'members' && members == null)) {
      loadTab();
    }
  }

  /// Opens the Members tab and scrolls it into view.
  void showMembers() {
    openTab('members');
    final target = tabsKey.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: VibeMotion.duration(context),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// Runs a server call with the busy flag, then reloads the space.
  Future<void> act(Future<void> Function(SpaceActions, Session) work) async {
    if (busy || loading) return;
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return;
    setState(() => busy = true);
    try {
      await work(ref.read(spaceActionsProvider), session);
      if (mounted) await load();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> leave(SocialSpace x) async {
    final ok = await confirmLeaveSpace(context, x);
    if (ok != true || !mounted) return;
    await act((a, s) async {
      await a.membership(s, x.spaceId, join: false);
      if (mounted) context.pop();
    });
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
      showSpaceRules(context, x);
    } else if (v == 'edit') {
      edit(x);
    } else if (v.startsWith('status:')) {
      final status = v.substring(7);
      act((a, s) async {
        await a.setStatus(s, x.spaceId, status);
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

  /// Opens [location] from a tab, then re-reads the plans on return.
  Future<void> openPlanRoute(String location) async {
    await context.push(location);
    if (mounted) {
      plans = null;
      loadTab();
    }
  }

  Future<void> manageMembers(SocialSpace x) async {
    await context.push('/spaces/${x.spaceId}/members');
    if (mounted) refresh();
  }

  void deleteEntry(SocialSpace x, SpaceEntry e) =>
      act((a, s) => a.deleteEntry(s, x.spaceId, e.entryId));

  void reportEntry(SpaceEntry e) => showReportSheet(
    context,
    ref,
    targetType: 'space_entry',
    targetId: e.entryId,
    name: e.author.name,
  );

  @override
  Widget build(BuildContext context) {
    final x = ref.watch(sessionProvider).asData?.value == null ? null : space;
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
              itemBuilder: (_) => spaceMenuEntries(
                x,
                ref.read(sessionProvider).asData?.value?.userId,
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: CustomScrollView(
              controller: scroll,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 40),
                  sliver: SliverMainAxisGroup(
                    slivers: [
                      SliverToBoxAdapter(child: _header(x)),
                      if (x != null && x.joined)
                        SpaceTabFade(
                          key: ValueKey(tab),
                          animate: fadeTabs,
                          sliver: _tabSlivers(x),
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

  /// Everything above the tab body: failure, spinner, identity, buttons, tabs.
  Widget _header(SocialSpace? x) {
    final tabs = x == null
        ? const <(String, String)>[]
        : [
            ('discussion', 'Discussion'),
            if (x.kind == 'community' && FeatureFlags.events)
              ('events', 'Events'),
            ('members', 'Members'),
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) FailureCard(error: error!, retry: load),
        if (x == null && loading && error == null) const VibeLoading(),
        if (x != null) ...[
          EntranceFade(child: SpaceIdentity(x)),
          const SizedBox(height: 20),
          EntranceFade(
            delayMs: 60,
            child: SpaceActionBar(
              space: x,
              busy: busy,
              loading: loading,
              onJoin: () => act((a, s) async {
                await a.membership(s, x.spaceId);
              }),
              onMembers: showMembers,
              onRsvp: (rsvp) => act((a, s) async {
                await a.membership(s, x.spaceId, rsvp: rsvp);
              }),
            ),
          ),
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
          ] else
            SpaceLockedDiscussion(
              kind: x.kind,
              pending: x.myState == 'pending',
            ),
        ],
      ],
    );
  }

  Widget _tabSlivers(SocialSpace x) => switch (tab) {
    'events' => SpaceEventsSliver(
      space: x,
      plans: plans,
      error: tabError,
      loading: tabLoading,
      onRetry: loadTab,
      onOpenRoute: openPlanRoute,
    ),
    'members' => SpaceMembersSliver(
      space: x,
      members: members,
      hasMore: membersCursor != null,
      loading: tabLoading,
      error: tabError,
      onRetry: loadTab,
      onMore: () => loadTab(more: true),
      onManage: () => manageMembers(x),
    ),
    _ => _discussionSlivers(x),
  };

  Widget _discussionSlivers(SocialSpace x) {
    final me = ref.read(sessionProvider).asData?.value?.userId;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: SpaceDiscussionHeader(
            space: x,
            text: text,
            busy: busy,
            loading: loading,
            hasEntries: entries.isNotEmpty,
            onPost: () => act((a, s) async {
              await a.addEntry(s, x.spaceId, text.text);
              text.clear();
            }),
          ),
        ),
        // Posts are built lazily as they scroll into view.
        SliverList.builder(
          itemCount: entries.length,
          itemBuilder: (context, i) {
            final e = entries[i];
            return SpaceEntryTile(
              key: ValueKey(e.entryId),
              entry: e,
              mine: e.author.userId == me,
              onDelete: () => deleteEntry(x, e),
              onReport: () => reportEntry(e),
            );
          },
        ),
        if (cursor != null)
          SliverToBoxAdapter(
            child: Center(
              child: TextButton(
                onPressed: loading ? null : () => load(more: true),
                child: const Text('Older thoughts'),
              ),
            ),
          ),
      ],
    );
  }
}
