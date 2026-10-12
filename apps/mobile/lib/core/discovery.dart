/// Temporary search selections. These are never written to privacy settings or
/// persisted as defaults. Multi-value filters use OR within each dimension.
class PeopleFilters {
  final List<String> interests, languages;
  final String country, vibe;

  /// "My surroundings": only people close to the member, nearest first. The
  /// device position is read automatically; there is nothing to configure.
  final bool nearby;

  /// Inclusive age range in years; null means no limit on that side.
  final int? ageMin, ageMax;

  /// `man`, `woman`, `nonbinary`, or empty for anyone.
  final String gender;

  /// Only people who are online and let this viewer see it. A real server-side
  /// filter (`online: true`), not a filter on the loaded page: the server counts
  /// session activity in the last two minutes (see docs/api/19).
  final bool online;
  PeopleFilters({
    Iterable<String> interests = const [],
    Iterable<String> languages = const [],
    this.country = '',
    this.vibe = '',
    this.nearby = false,
    this.ageMin,
    this.ageMax,
    this.gender = '',
    this.online = false,
  }) : interests = List.unmodifiable(interests),
       languages = List.unmodifiable(languages);
  bool get isEmpty =>
      interests.isEmpty &&
      languages.isEmpty &&
      country.isEmpty &&
      vibe.isEmpty &&
      !nearby &&
      ageMin == null &&
      ageMax == null &&
      gender.isEmpty &&
      !online;
  bool get hasAge => ageMin != null || ageMax != null;

  /// How many separate filters are on: each language and interest counts, the
  /// age range counts once.
  int get count =>
      interests.length +
      languages.length +
      (country.isEmpty ? 0 : 1) +
      (vibe.isEmpty ? 0 : 1) +
      (nearby ? 1 : 0) +
      (hasAge ? 1 : 0) +
      (gender.isEmpty ? 0 : 1) +
      (online ? 1 : 0);

  /// The same selection, field for field (the order of values does not matter).
  bool sameAs(PeopleFilters other) =>
      nearby == other.nearby &&
      online == other.online &&
      ageMin == other.ageMin &&
      ageMax == other.ageMax &&
      gender == other.gender &&
      country == other.country &&
      vibe == other.vibe &&
      _sameSet(interests, other.interests) &&
      _sameSet(languages, other.languages);

  static bool _sameSet(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  /// The search body. Nearby is not a search field; it selects another route.
  Map<String, dynamic> toJson({String? cursor}) => {
    'interests': interests,
    'languages': languages,
    'country': country,
    'vibe': vibe,
    'ageMin': ?ageMin,
    'ageMax': ?ageMax,
    if (gender.isNotEmpty) 'gender': gender,
    if (online) 'online': true,
    if (cursor != null) ...{'cursor': cursor},
  };
}
