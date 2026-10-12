import '../shared/avatar_gradient.dart' show stableHash;

/// What the new-chat card says and offers, kept apart from the widget so it can
/// be tested as plain functions. Nothing here is ever sent: a starter is only
/// text that lands in the composer for the person to edit or send.
///
/// Tone: casual and curious, one open question at a time. Starters never ask
/// for personal data (real name, age, school, where someone lives, contact
/// details, photos) and are never flirty; they are about things people enjoy.

/// How one interest is talked about, and what to ask about it.
class InterestTopic {
  /// The word as the onboarding list spells it.
  final String name;
  final String emoji;

  /// "love" or "like": the verb that sounds natural for this interest.
  final String verb;

  /// Four natural openers about it.
  final List<String> starters;
  const InterestTopic(this.name, this.emoji, this.verb, this.starters);
}

/// The twelve interests onboarding offers.
const interestTopics = <InterestTopic>[
  InterestTopic('Music', '🎧', 'love', [
    'what’s on repeat lately? 🎧',
    'send me a song you’d never skip',
    'best song you heard this week?',
    'what’s your go-to playlist?',
  ]),
  InterestTopic('Technology', '💻', 'like', [
    'any app you can’t live without?',
    'coolest thing you’ve tried lately?',
    'what gadget do you use daily?',
    'tech take: what’s overrated?',
  ]),
  InterestTopic('Travel', '✈️', 'love', [
    'best trip you’ve ever taken?',
    'what’s on your travel wishlist?',
    'window seat or aisle? ✈️',
    'dream trip, money no object?',
  ]),
  InterestTopic('Photography', '📷', 'love', [
    'what do you love shooting?',
    'phone or camera person? 📷',
    'best photo you’ve taken lately?',
    'got a shot you’re proud of?',
  ]),
  InterestTopic('Movies', '🎬', 'love', [
    'seen anything good lately? 🎬',
    'what’s your comfort movie?',
    'a hyped movie you didn’t like?',
    'best movie this year so far?',
  ]),
  InterestTopic('Art', '🎨', 'love', [
    'what have you made lately? 🎨',
    'which artist are you into?',
    'digital or on paper?',
    'what got you into art?',
  ]),
  InterestTopic('Gaming', '🎮', 'like', [
    'what are you playing now? 🎮',
    'all-time favourite game?',
    'co-op or competitive?',
    'a game you keep replaying?',
  ]),
  InterestTopic('Reading', '📚', 'love', [
    'what are you reading now? 📚',
    'best book this year so far?',
    'paper, ebook or audiobook?',
    'a book you’d recommend?',
  ]),
  InterestTopic('Fitness', '💪', 'like', [
    'what’s your go-to workout? 💪',
    'morning or evening training?',
    'any goal you’re chasing?',
    'favourite way to move?',
  ]),
  InterestTopic('Food', '🍜', 'love', [
    'best thing you ate this week? 🍜',
    'go-to comfort food?',
    'sweet or savoury?',
    'a dish you’re proud of?',
  ]),
  InterestTopic('Nature', '🌿', 'love', [
    'favourite place outside? 🌿',
    'mountains or beaches?',
    'best walk or hike you’ve done?',
    'what do you love outdoors?',
  ]),
  InterestTopic('Learning', '🧠', 'love', [
    'learning anything new? 🧠',
    'best thing you learned lately?',
    'any rabbit holes lately?',
    'what do you want to get better at?',
  ]),
];

/// Openers for any chat, used when nothing is shared and to round the set off.
const genericStarters = <String>[
  '👋 hey!',
  'what’s your vibe today?',
  'what are you up to?',
  'best part of your week so far?',
  'what are you into lately?',
  'something that made you smile today?',
  'recommend me something to watch?',
  'what’s your comfort show?',
  'how’s your day going?',
  'your favourite way to unwind?',
];

InterestTopic? topicFor(String interest) {
  final key = interest.trim().toLowerCase();
  for (final t in interestTopics) {
    if (t.name.toLowerCase() == key) return t;
  }
  return null;
}

/// Longest custom interest printed in the line before it is cut with "…".
const _maxCustomInterest = 24;

String _phrase(String interest) {
  final topic = topicFor(interest);
  if (topic != null) return '${topic.name} ${topic.emoji}';
  final name = interest.trim();
  return name.length > _maxCustomInterest
      ? '${name.substring(0, _maxCustomInterest - 1).trimRight()}…'
      : name;
}

String _verbFor(String interest) => topicFor(interest)?.verb ?? 'like';

/// "You both love Music 🎧", "You both like Gaming 🎮", or for two,
/// "You both love Music 🎧 and Travel ✈️" ("like" unless both are loved). At
/// most two interests are mentioned. Null when [shared] has
/// nothing usable, so the card falls back to the plain prompt.
String? sharedInterestLine(List<String> shared) {
  final usable = [
    for (final s in shared)
      if (s.trim().isNotEmpty) s.trim(),
  ].take(2).toList();
  if (usable.isEmpty) return null;
  final first = usable.first;
  if (usable.length == 1) {
    return 'You both ${_verbFor(first)} ${_phrase(first)}';
  }
  // One verb for the pair: "love" only when both are things people love.
  final verb = _verbFor(first) == 'love' && _verbFor(usable[1]) == 'love'
      ? 'love'
      : 'like';
  return 'You both $verb ${_phrase(first)} and ${_phrase(usable[1])}';
}

/// [count] items from [pool], starting at a place picked by [seed] and wrapping
/// round, so the same seed always gives the same items.
List<T> _rotate<T>(List<T> pool, int seed, int count) => [
  for (var i = 0; i < count && i < pool.length; i++)
    pool[(seed + i) % pool.length],
];

/// Three or four icebreakers for this conversation. With shared interests: one
/// about the first, then one about the second (or another about the first), then
/// one easy general opener, three in all. With none: four general ones. The
/// pick is a pure function of [conversationId] and the interests, so the same
/// chat shows the same set every time it is opened.
List<String> startersFor(String conversationId, List<String> shared) {
  final seed = stableHash(conversationId);
  final topics = <InterestTopic>[for (final s in shared.take(2)) ?topicFor(s)];
  if (topics.isEmpty) return _rotate(genericStarters, seed, 4);
  final a = _rotate(topics.first.starters, seed, 2);
  final second = topics.length > 1
      ? _rotate(topics[1].starters, seed >> 3, 1)[0]
      : a[1];
  return [a[0], second, _rotate(genericStarters, seed >> 5, 1)[0]];
}
