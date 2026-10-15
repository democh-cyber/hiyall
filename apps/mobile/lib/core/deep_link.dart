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
  String? _owner;
  bool _sessionSeen = false;

  Uri? get pending => _pending;

  /// True once a signed-in session was active in this launch. From then on a
  /// page the router sent someone away from is never remembered: it is where
  /// they signed out or were signed out, not somewhere they were heading.
  bool get sessionSeen => _sessionSeen;

  /// Remembers [uri] unless it is an entry step or the plain home page, or a
  /// session was already active in this launch.
  void remember(Uri uri) {
    if (_sessionSeen) return;
    final path = uri.path.isEmpty ? '/' : uri.path;
    if (entryRoutes.contains(path) || path == '/' || path == '/home') return;
    _pending = uri;
    _owner = null;
  }

  /// A session for [userId] is active. A remembered link then belongs to that
  /// account and is dropped if a different one shows up.
  void sessionActive(String userId) {
    _sessionSeen = true;
    if (_pending != null && _owner != null && _owner != userId) {
      _pending = null;
    }
    if (_pending != null) _owner = userId;
  }

  /// The remembered location, cleared. Null when it was recorded for another
  /// account than [userId].
  String? take([String? userId]) {
    final uri = _pending, owner = _owner;
    _pending = null;
    _owner = null;
    if (uri == null || (userId != null && owner != null && owner != userId)) {
      return null;
    }
    return uri.toString();
  }

  /// Forgets the link (sign-out, expiry, account deletion). The "a session was
  /// active" mark stays: this launch has had a signed-in session.
  void clear() {
    _pending = null;
    _owner = null;
  }
}

final deepLinkMemoryProvider = Provider<DeepLinkMemory>(
  (ref) => DeepLinkMemory(),
);
