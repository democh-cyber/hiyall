import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';

const anjaliId = '019a4000-0000-7000-8000-000000000001';
const nikoId = '019a4000-0000-7000-8000-000000000002';
final apiProvider = Provider<ApiClient>((ref) => ApiClient());
final sessionProvider =
    NotifierProvider<SessionController, AsyncValue<Session?>>(
      SessionController.new,
    );

class SessionController extends Notifier<AsyncValue<Session?>> {
  @override
  AsyncValue<Session?> build() => const AsyncData(null);
  Future<void> login(String id) async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(apiProvider).signInDevelopment(id),
    );
  }

  Future<void> logout() async {
    final session = state.asData?.value;
    // Keep the credential until the server acknowledges revocation; failures are visible.
    if (session != null) {
      try {
        await ref.read(apiProvider).logout(session);
      } on ApiFailure catch (error) {
        if (error.status != 401) rethrow;
      }
    }
    state = const AsyncData(null);
  }
}

Session requireSession(Ref ref) {
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null) throw const ApiFailure('Sign in to continue.');
  return session;
}

// Authorization/visibility failures are stable states; only transient failures retry.
Duration? apiReadRetry(int attempt, Object error) {
  if (error is ApiFailure &&
      error.status != null &&
      error.status! >= 400 &&
      error.status! < 500 &&
      error.status != 429) {
    return null;
  }
  return ProviderContainer.defaultRetry(attempt, error);
}

final profileProvider = FutureProvider<Profile>(
  (ref) => ref.watch(apiProvider).profile(requireSession(ref)),
  retry: apiReadRetry,
);
final privacyProvider = FutureProvider<Privacy>(
  (ref) => ref.watch(apiProvider).privacy(requireSession(ref)),
  retry: apiReadRetry,
);
final sessionsProvider = FutureProvider<Map<String, dynamic>>(
  (ref) => ref.watch(apiProvider).sessions(requireSession(ref)),
  retry: apiReadRetry,
);
final otherProfileProvider = FutureProvider.autoDispose.family<Profile, String>(
  (ref, id) => ref.watch(apiProvider).otherProfile(requireSession(ref), id),
  retry: apiReadRetry,
);
