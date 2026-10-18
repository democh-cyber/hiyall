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

  /// Only people at this level or above (1 to 6) in at least one of [languages]; 0 is any level. Needs
  /// [languages].
  final int languageMinLevel;

  /// Personality tag ids; any one of them matches.
  final List<String> personalityTags;

  /// "Same country": the server fills in the member's own country.
  final bool sameCountry;

  /// "Possible matches": people ranked by what they share with the member. Like [nearby] it selects another
  /// route and is not a search field; the other filters do not apply to it.
  final bool possible;
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
    this.languageMinLevel = 0,
    Iterable<String> personalityTags = const [],
    this.sameCountry = false,
    this.possible = false,
  }) : interests = List.unmodifiable(interests),
       languages = List.unmodifiable(languages),
       personalityTags = List.unmodifiable(personalityTags);
  bool get isEmpty =>
      interests.isEmpty &&
      languages.isEmpty &&
      country.isEmpty &&
      vibe.isEmpty &&
      !nearby &&
      ageMin == null &&
      ageMax == null &&
      gender.isEmpty &&
      !online &&
      languageMinLevel == 0 &&
      personalityTags.isEmpty &&
      !sameCountry &&
      !possible;
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
      (online ? 1 : 0) +
      personalityTags.length +
      (languageMinLevel > 0 ? 1 : 0) +
      (sameCountry ? 1 : 0) +
      (possible ? 1 : 0);

  /// The same selection, field for field (the order of values does not matter).
  bool sameAs(PeopleFilters other) =>
      nearby == other.nearby &&
      possible == other.possible &&
      sameCountry == other.sameCountry &&
      languageMinLevel == other.languageMinLevel &&
      _sameSet(personalityTags, other.personalityTags) &&
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
    if (languageMinLevel > 0 && languages.isNotEmpty)
      'languageMinLevel': languageMinLevel,
    if (personalityTags.isNotEmpty) 'personalityTags': personalityTags,
    if (sameCountry) 'sameCountry': true,
    if (cursor != null) ...{'cursor': cursor},
  };

  /// This selection with some parts changed. Pass only what changes.
  PeopleFilters copyWith({
    Iterable<String>? interests,
    Iterable<String>? languages,
    String? country,
    String? vibe,
    bool? nearby,
    int? Function()? ageMin,
    int? Function()? ageMax,
    String? gender,
    bool? online,
    int? languageMinLevel,
    Iterable<String>? personalityTags,
    bool? sameCountry,
    bool? possible,
  }) => PeopleFilters(
    interests: interests ?? this.interests,
    languages: languages ?? this.languages,
    country: country ?? this.country,
    vibe: vibe ?? this.vibe,
    nearby: nearby ?? this.nearby,
    ageMin: ageMin == null ? this.ageMin : ageMin(),
    ageMax: ageMax == null ? this.ageMax : ageMax(),
    gender: gender ?? this.gender,
    online: online ?? this.online,
    languageMinLevel: languageMinLevel ?? this.languageMinLevel,
    personalityTags: personalityTags ?? this.personalityTags,
    sameCountry: sameCountry ?? this.sameCountry,
    possible: possible ?? this.possible,
  );

  /// What is kept on the device as the member's last-used filters: the search fields, not the mode (Nearby and
  /// possible matches are modes, not saved choices).
  Map<String, dynamic> toSaved() => {
    'interests': interests,
    'languages': languages,
    'country': country,
    'vibe': vibe,
    'ageMin': ?ageMin,
    'ageMax': ?ageMax,
    if (gender.isNotEmpty) 'gender': gender,
    if (online) 'online': true,
    if (languageMinLevel > 0) 'languageMinLevel': languageMinLevel,
    'personalityTags': personalityTags,
    if (sameCountry) 'sameCountry': true,
  };

  /// Reads [toSaved]; anything unreadable gives the empty selection.
  static PeopleFilters fromSaved(Object? json) {
    if (json is! Map) return PeopleFilters();
    List<String> list(String key) => [
      for (final v in json[key] as List? ?? const [])
        if (v is String && v.isNotEmpty) v,
    ];
    int? number(String key) =>
        json[key] is num ? (json[key] as num).toInt() : null;
    return PeopleFilters(
      interests: list('interests'),
      languages: list('languages'),
      country: json['country'] as String? ?? '',
      vibe: json['vibe'] as String? ?? '',
      ageMin: number('ageMin'),
      ageMax: number('ageMax'),
      gender: json['gender'] as String? ?? '',
      online: json['online'] == true,
      languageMinLevel: (number('languageMinLevel') ?? 0).clamp(0, 6),
      personalityTags: list('personalityTags'),
      sameCountry: json['sameCountry'] == true,
    );
  }
}
