import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'auth/firebase_config.dart';
import 'auth/reauth.dart';

/// A signed-in member whose account is scheduled for deletion. They have no
/// ordinary session: the app shows only the screen with the date and "Keep my
/// account", and the server refuses everything else for them. [session] is
/// good for the deletion status, the cancel and sign-out routes.
class PendingAccount {
  final Session session;
  final DeletionStatus status;
  const PendingAccount(this.session, this.status);
}

final pendingAccountProvider =
    NotifierProvider<PendingAccountController, PendingAccount?>(
      PendingAccountController.new,
    );

class PendingAccountController extends Notifier<PendingAccount?> {
  @override
  PendingAccount? build() => null;
  void set(PendingAccount? value) => state = value;
}

/// Asks the server whether [session] belongs to an account in its deletion
/// grace period. Null for an ordinary account, and when the question cannot be
/// answered: the normal start-up then reports what is wrong.
Future<PendingAccount?> pendingDeletionOf(
  ApiClient api,
  Session session,
) async {
  try {
    final status = await api.deletionStatus(session);
    return status.pending ? PendingAccount(session, status) : null;
  } catch (_) {
    return null;
  }
}

/// When the account the member just deleted ends, for the screen that says so
/// after they were signed out (null when there is nothing to show).
final deletionScheduledProvider =
    NotifierProvider<DeletionScheduled, DateTime?>(DeletionScheduled.new);

class DeletionScheduled extends Notifier<DateTime?> {
  @override
  DateTime? build() => null;
  void set(DateTime? due) => state = due;
}

/// How the member confirms it's them again. Replaced by a fake in tests.
final reauthenticatorProvider = Provider<Reauthenticator>(
  (ref) => FirebaseConfig.isConfigured
      ? FirebaseReauthenticator()
      : const NoReauthenticator(),
);

/// How many times Apple gave no authorization code while a member tried to delete
/// their account, per user, for as long as the app process lives. Closing the
/// delete screen and opening it again therefore does not hand out two more
/// Apple prompts.
final appleDeletionMissesProvider =
    NotifierProvider<AppleDeletionMisses, Map<String, int>>(
      AppleDeletionMisses.new,
    );

class AppleDeletionMisses extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  int of(String userId) => state[userId] ?? 0;

  int add(String userId) {
    final next = of(userId) + 1;
    state = {...state, userId: next};
    return next;
  }

  void clear(String userId) {
    if (state.containsKey(userId)) {
      state = {...state}..remove(userId);
    }
  }
}
