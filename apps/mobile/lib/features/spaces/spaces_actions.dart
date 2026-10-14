import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/state.dart';

/// Every server call the Spaces screens make, in one place. The widgets keep
/// their own session, mounted and generation guards; this only wraps the call.
/// It reads [apiProvider] at call time so test overrides keep working.
class SpaceActions {
  final Ref _ref;
  SpaceActions(this._ref);

  ApiClient get _api => _ref.read(apiProvider);

  Future<ApiPage<SocialSpace>> list(
    Session s,
    String kind, {
    String? cursor,
    String? parentId,
    bool mine = false,
  }) => _api.spaces(s, kind, cursor: cursor, parentId: parentId, mine: mine);

  Future<SocialSpace> get(Session s, String id) => _api.space(s, id);

  Future<SocialSpace> create(Session s, Map<String, dynamic> body) =>
      _api.createSpace(s, body);

  Future<SocialSpace> update(Session s, String id, Map<String, dynamic> body) =>
      _api.updateSpace(s, id, body);

  /// Joins (or sets the RSVP), or leaves when [join] is false.
  Future<SocialSpace> membership(
    Session s,
    String id, {
    bool join = true,
    String rsvp = 'going',
  }) => _api.spaceMembership(s, id, join: join, rsvp: rsvp);

  Future<SocialSpace> setStatus(Session s, String id, String status) =>
      _api.spaceStatus(s, id, status);

  Future<ApiPage<SpaceMember>> members(
    Session s,
    String id, {
    String state = 'active',
    String? cursor,
  }) => _api.spaceMembers(s, id, state: state, cursor: cursor);

  Future<void> invite(Session s, String id, String username) =>
      _api.inviteSpaceUser(s, id, username);

  Future<void> memberAction(Session s, String id, String user, String action) =>
      _api.spaceMemberAction(s, id, user, action);

  Future<ApiPage<SpaceEntry>> entries(Session s, String id, [String? cursor]) =>
      _api.spaceEntries(s, id, cursor);

  Future<void> addEntry(Session s, String id, String text) =>
      _api.addSpaceEntry(s, id, text);

  Future<void> deleteEntry(Session s, String id, String entry) =>
      _api.deleteSpaceEntry(s, id, entry);
}

final spaceActionsProvider = Provider<SpaceActions>(SpaceActions.new);

/// One space for the editor, which only hosts may open.
final editSpaceProvider = FutureProvider.autoDispose
    .family<SocialSpace, String>((ref, id) async {
      final s = ref.watch(sessionProvider).asData?.value;
      if (s == null) throw const ApiFailure('Sign in to edit a space');
      return ref.watch(apiProvider).space(s, id);
    });
