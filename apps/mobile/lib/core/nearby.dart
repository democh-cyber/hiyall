part of 'api.dart';

/// Whether the member's approximate location is currently shared. The API
/// never sends coordinates back.
class LocationStatus {
  final bool sharing;
  final DateTime? updatedAt;
  const LocationStatus(this.sharing, [this.updatedAt]);
  factory LocationStatus.fromJson(Map<String, dynamic> json) => LocationStatus(
    json['sharing'] as bool? ?? false,
    json['updatedAt'] == null
        ? null
        : DateTime.parse(json['updatedAt'] as String),
  );
}

/// The "Show me in Nearby" switch. Off by default for everyone; [minor] is
/// whether the server treats the member as under 18 (stronger explainer, a
/// coarser area). Coordinates never come back.
class NearbyStatus {
  final bool visible, sharing, minor;
  final DateTime? updatedAt;
  const NearbyStatus({
    this.visible = false,
    this.sharing = false,
    this.minor = false,
    this.updatedAt,
  });
  factory NearbyStatus.fromJson(Map<String, dynamic> json) => NearbyStatus(
    visible: json['visible'] as bool? ?? false,
    sharing: json['sharing'] as bool? ?? false,
    minor: json['minor'] as bool? ?? false,
    updatedAt: json['updatedAt'] == null
        ? null
        : DateTime.parse(json['updatedAt'] as String),
  );
}

mixin NearbyApi {
  Future<dynamic> _request(
    String method,
    String path, {
    String? token,
    Object? body,
    // ignore: unused_element_parameter
    String? version,
  });

  Future<NearbyStatus> nearbyStatus(Session s) async => NearbyStatus.fromJson(
    await _request('GET', '/v1/me/nearby', token: s.token)
        as Map<String, dynamic>,
  );

  /// Turns "Show me in Nearby" on. Stores no location; send one afterwards.
  Future<NearbyStatus> showMeInNearby(Session s) async => NearbyStatus.fromJson(
    await _request('PUT', '/v1/me/nearby', token: s.token)
        as Map<String, dynamic>,
  );

  /// Turns it off and deletes the stored area on the server.
  Future<NearbyStatus> hideFromNearby(Session s) async => NearbyStatus.fromJson(
    await _request('DELETE', '/v1/me/nearby', token: s.token)
        as Map<String, dynamic>,
  );

  Future<LocationStatus> locationStatus(Session s) async =>
      LocationStatus.fromJson(
        await _request('GET', '/v1/me/location', token: s.token)
            as Map<String, dynamic>,
      );

  /// Starts (or refreshes) sharing. The server rounds the position to about a
  /// kilometre before storing it.
  Future<LocationStatus> shareLocation(
    Session s,
    double latitude,
    double longitude,
  ) async => LocationStatus.fromJson(
    await _request(
      'PUT',
      '/v1/me/location',
      token: s.token,
      body: {'latitude': latitude, 'longitude': longitude},
    ) as Map<String, dynamic>,
  );

  Future<void> stopSharingLocation(Session s) async =>
      await _request('DELETE', '/v1/me/location', token: s.token);

  /// People close to the member, nearest first, narrowed by the same filters
  /// as the main search. Each [Profile.distanceKm] is a rounded-up bucket, never
  /// a precise distance. Throws [ApiFailure] with code `LOCATION_NOT_SHARED`
  /// until the member's position has been read.
  Future<ApiPage<Profile>> nearby(
    Session s, {
    PeopleFilters? filters,
    int radiusKm = 50, // one of 5, 10, 15, 25, 50, 100
    String? cursor,
  }) async {
    final body = {
      ...?filters?.toJson(),
      'radiusKm': radiusKm,
      'cursor': ?cursor,
    };
    return ApiPage.fromJson(
      await _request('POST', '/v1/discover/nearby', token: s.token, body: body)
          as Map<String, dynamic>,
      Profile.fromJson,
    );
  }
}
