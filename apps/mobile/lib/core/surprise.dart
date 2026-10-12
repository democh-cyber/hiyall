import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';

/// "Someone new is one hello away": the Discover card that opens the profile
/// of a person picked from the results the server already returned.
///
/// This is not matching. Nothing is queued, nobody is paired and no chat starts:
/// the pick is client-side, from the people already loaded for this viewer (the
/// server has applied blocks, age bands, discoverability and suspensions), and
/// the only effect is opening a profile. The card calls one callback
/// (`SurpriseCard.onSurprise`); a future matching flow can replace what that
/// callback does without touching the card.
enum SurpriseStatus { ready, loading, nothing, error }

/// How many people should be loaded before a pick, and how many extra pages the
/// card may fetch to get there.
const surpriseMinPool = 10;
const surpriseMaxPages = 3;

/// The source of randomness; replaced in tests so a pick is predictable.
final surpriseRandomProvider = Provider<Random>((ref) => Random());

/// A random person from [people], or null when there is no one new.
///
/// [last] (the previous pick) is never returned again, even when it is the only
/// one left. People in [known] (already followed, or already in a chat) are
/// skipped while anyone else is left; when everyone is known, one of them is
/// still a fine surprise.
Profile? pickSurprise(
  Iterable<Profile> people, {
  String? last,
  Set<String> known = const {},
  required Random random,
}) {
  final fresh = [
    for (final p in people)
      if (p.userId != last && !p.locked) p,
  ];
  if (fresh.isEmpty) return null;
  final unknown = [
    for (final p in fresh)
      if (!known.contains(p.userId) && p.relationship?.following != 'active') p,
  ];
  final pool = unknown.isEmpty ? fresh : unknown;
  return pool[random.nextInt(pool.length)];
}
