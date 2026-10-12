import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// The docked destinations. Pages below these live inside the app shell.
const shellRoots = [
  '/home',
  '/chats',
  '/discover',
  '/notifications',
  '/profile',
];

bool _inShell(String path) =>
    shellRoots.any((root) => path == root || path.startsWith('$root/'));

/// Where [userId]'s profile opens from the current page. Inside the dock it
/// stays in the dock; from a full-screen page (a space, Find people) it opens
/// above it, since a docked route can't be stacked on a page outside the dock.
String personPath(BuildContext context, String userId) {
  final here = GoRouter.maybeOf(context)?.state.uri.path ?? '';
  return _inShell(here) ? '/discover/person/$userId' : '/person/$userId';
}

/// Opens a profile on top of the current page, so back returns here.
Future<void> openPerson(BuildContext context, String userId) =>
    context.push<void>(personPath(context, userId));

/// Back from a page that may also be opened directly (a link or `go`): pops
/// when there's somewhere to return to, otherwise goes to [fallback].
void goBack(BuildContext context, [String fallback = '/discover']) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(fallback);
  }
}
