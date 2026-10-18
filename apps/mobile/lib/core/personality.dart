import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Icons;

/// A personality tag a member can put on their profile. [id] is what the server stores (the fixed list in
/// `domain.PersonalityTags`); the words and icons are the app's own. A profile holds none, or three to five.
class PersonalityTag {
  final String id, label;
  final IconData icon;
  const PersonalityTag(this.id, this.label, this.icon);
}

/// The fewest and the most tags a member who picks any must pick.
const minPersonalityTags = 3, maxPersonalityTags = 5;

/// The 19 tags, in the order the picker shows them.
const personalityTags = <PersonalityTag>[
  PersonalityTag('curious', 'Curious', Icons.lightbulb_outline_rounded),
  PersonalityTag('night_owl', 'Night owl', Icons.nightlight_outlined),
  PersonalityTag('early_bird', 'Early bird', Icons.wb_twilight_rounded),
  PersonalityTag('homebody', 'Homebody', Icons.chair_outlined),
  PersonalityTag('explorer', 'Explorer', Icons.explore_outlined),
  PersonalityTag('bookish', 'Bookish', Icons.menu_book_rounded),
  PersonalityTag('foodie', 'Foodie', Icons.ramen_dining_outlined),
  PersonalityTag('maker', 'Maker', Icons.handyman_outlined),
  PersonalityTag('playful', 'Playful', Icons.celebration_outlined),
  PersonalityTag('sporty', 'Sporty', Icons.sports_basketball_outlined),
  PersonalityTag('music_lover', 'Music lover', Icons.headphones_rounded),
  PersonalityTag('film_fan', 'Film fan', Icons.movie_outlined),
  PersonalityTag('jokester', 'Jokester', Icons.sentiment_very_satisfied),
  PersonalityTag('deep_thinker', 'Deep thinker', Icons.psychology_alt_outlined),
  PersonalityTag('planner', 'Planner', Icons.event_note_outlined),
  PersonalityTag('spontaneous', 'Spontaneous', Icons.bolt_rounded),
  PersonalityTag('empathetic', 'Empathetic', Icons.favorite_border_rounded),
  PersonalityTag('chatty', 'Chatty', Icons.forum_outlined),
  PersonalityTag('low_key', 'Low-key', Icons.spa_outlined),
];

/// The tag with this id, or null for one this app version does not know (a newer server may add more).
PersonalityTag? personalityTagById(String id) {
  for (final tag in personalityTags) {
    if (tag.id == id) return tag;
  }
  return null;
}

/// The label of a tag id; an unknown id is shown as readable words rather than hidden.
String personalityTagLabel(String id) =>
    personalityTagById(id)?.label ??
    (id.isEmpty
        ? id
        : '${id[0].toUpperCase()}${id.substring(1).replaceAll('_', ' ')}');
