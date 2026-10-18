import 'package:flutter/material.dart';

/// The topics a post or story can carry (`GET /v1/topics`, docs/api/27-stories-notices-support.md). The server
/// stores and sends only the name; the words and the icon are this app's own. The list below is what a build
/// offers when the server cannot be asked, and the order a fresh server sends today.
const topicNames = [
  'language',
  'music',
  'food',
  'travel',
  'games',
  'art',
  'sport',
  'study',
];

const _labels = {
  'language': 'Languages',
  'music': 'Music',
  'food': 'Food',
  'travel': 'Travel',
  'games': 'Games',
  'art': 'Art',
  'sport': 'Sport',
  'study': 'Study',
};

/// The words for a topic. A name a newer server added is shown as it came, so nothing is ever hidden.
String topicLabel(String name) => _labels[name] ?? name;

/// The icon for a topic; a name this build does not know gets a plain tag.
IconData topicIcon(String name) => switch (name) {
  'language' => Icons.translate_rounded,
  'music' => Icons.music_note_rounded,
  'food' => Icons.restaurant_rounded,
  'travel' => Icons.flight_takeoff_rounded,
  'games' => Icons.sports_esports_rounded,
  'art' => Icons.palette_outlined,
  'sport' => Icons.sports_soccer_rounded,
  'study' => Icons.menu_book_rounded,
  _ => Icons.tag_rounded,
};
