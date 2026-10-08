/// Temporary search selections. These are never written to privacy settings or
/// persisted as defaults. Multi-value filters use OR within each dimension.
class PeopleFilters {
  final List<String> interests, languages;
  final String country, vibe;
  PeopleFilters({
    Iterable<String> interests = const [],
    Iterable<String> languages = const [],
    this.country = '',
    this.vibe = '',
  }) : interests = List.unmodifiable(interests),
       languages = List.unmodifiable(languages);
  bool get isEmpty =>
      interests.isEmpty && languages.isEmpty && country.isEmpty && vibe.isEmpty;
  Map<String, dynamic> toJson({String? cursor}) => {
    'interests': interests,
    'languages': languages,
    'country': country,
    'vibe': vibe,
    if (cursor != null) ...{'cursor': cursor},
  };
}
