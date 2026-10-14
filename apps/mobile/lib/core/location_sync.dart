import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'location_service.dart';

/// Why the last position read failed, so Discover can explain an empty
/// "Nearby" list. Null when the position was read or not yet tried.
final locationProblemProvider =
    NotifierProvider<LocationProblemState, LocationProblem?>(
      LocationProblemState.new,
    );

class LocationProblemState extends Notifier<LocationProblem?> {
  @override
  LocationProblem? build() => null;
  void set(LocationProblem? problem) => state = problem;
}

/// Wraps the signed-in app. It used to read the device position on every
/// launch and resume and upload it; it no longer reads anything. Location is
/// requested only when the person opens Nearby and chooses "Show me in
/// Nearby" after the explainer (features/nearby_optin.dart), or switches it on
/// in Settings. The wrapper stays so the app shell does not change.
class LocationSync extends StatelessWidget {
  final Widget child;
  const LocationSync({super.key, required this.child});
  @override
  Widget build(BuildContext context) => child;
}
