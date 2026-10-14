import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/state.dart';
import '../../core/user_error.dart';
import 'space_format.dart';
import 'space_members_parts.dart';
import 'spaces_actions.dart';

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
    if (spaceMemberStates.containsKey(widget.initialState)) {
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
      final a = ref.read(spaceActionsProvider);
      final x = await a.get(s, widget.id);
      final p = await a.members(
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
          error = friendlyError(e);
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
        await ref.read(spaceActionsProvider).invite(s, widget.id, user);
      } else {
        await ref
            .read(spaceActionsProvider)
            .memberAction(s, widget.id, user, action);
      }
      if (mounted) {
        setState(() => busy = false);
        await load();
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
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
    final me = ref.read(sessionProvider).asData?.value?.userId;
    return Scaffold(
      appBar: AppBar(
        systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        title: const Text('Participants'),
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 32),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: SpaceMembersHeader(
                      space: x,
                      invite: invite,
                      busy: busy,
                      hasMembers: members.isNotEmpty,
                      state: state,
                      error: error,
                      onAction: action,
                      onState: (k) {
                        state = k;
                        load();
                      },
                      onRetry: load,
                    ),
                  ),
                  // Participants are built lazily as they scroll into view.
                  SliverList.builder(
                    itemCount: members.length,
                    itemBuilder: (context, i) => SpaceMemberTile(
                      member: members[i],
                      space: x,
                      meId: me,
                      onAction: action,
                    ),
                  ),
                  if (cursor != null)
                    SliverToBoxAdapter(
                      child: Center(
                        child: TextButton(
                          onPressed: busy ? null : () => load(more: true),
                          child: const Text('Load more'),
                        ),
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
}
