import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Pages that are steps on the way in (or out), never a destination worth
/// returning to after sign-in.
const entryRoutes = {
  '/splash',
  '/welcome',
  '/login',
  '/signup',
  '/forgot-password',
  '/account-deleted',
  '/account-deletion',
  '/verify-email',
  '/onboarding',
  '/update',
};

/// The page someone was trying to open (a notification, a shared link, a web
/// URL typed in) while the app sent them through splash, welcome, log in,
/// email verification or onboarding. Taken once they are in.
///
/// Plain memory, not provider state: the router writes it from its redirect,
/// where changing watched state would trigger another redirect.
class DeepLinkMemory {
  Uri? _pending;

  Uri? get pending => _pending;

  /// Remembers [uri] unless it is an entry step or the plain home page.
  void remember(Uri uri) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    if (entryRoutes.contains(path) || path == '/' || path == '/home') return;
    _pending = uri;
  }

  /// The remembered location, cleared.
  String? take() {
    final uri = _pending;
    _pending = null;
    return uri?.toString();
  }

  void clear() => _pending = null;
}

final deepLinkMemoryProvider = Provider<DeepLinkMemory>(
  (ref) => DeepLinkMemory(),
);
