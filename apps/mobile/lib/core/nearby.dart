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

mixin NearbyApi {
  Future<dynamic> _request(
    String method,
    String path, {
    String? token,
    Object? body,
    // ignore: unused_element_parameter
    String? version,
  });

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
    int radiusKm = 50,
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
