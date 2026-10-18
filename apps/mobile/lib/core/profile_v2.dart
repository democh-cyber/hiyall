part of 'api.dart';

/// A person in a recent-visitors or places-visited list, and when the visit last happened.
class VisitedPerson {
  final Person user;
  final DateTime visitedAt;

  /// The signed-in member's own follow state on [user] (none, pending, active).
  final String following;
  const VisitedPerson(this.user, this.visitedAt, [this.following = 'none']);
  factory VisitedPerson.fromJson(Map<String, dynamic> json) => VisitedPerson(
    Person.fromJson(json['user'] as Map),
    DateTime.parse(json['visitedAt'] as String),
    json['following'] as String? ?? 'none',
  );
}

/// The member's own gallery and the most photos it can hold (from the server's entitlements).
class Gallery {
  final List<GalleryPhoto> photos;
  final int max;
  const Gallery(this.photos, this.max);
  factory Gallery.fromJson(Map<String, dynamic> json) => Gallery(
    List.unmodifiable(
      (json['photos'] as List? ?? const []).map(
        (v) => GalleryPhoto.fromJson(v as Map),
      ),
    ),
    (json['max'] as num?)?.toInt() ?? 8,
  );
}

/// Profile and discovery v2 (docs/api/25-profile-and-discovery-v2.md): the photo gallery, possible matches, the
/// recent-visitor list and the member's own visit history. Mixed into [ApiClient] so tests can override them.
mixin ProfileV2Api {
  Future<dynamic> _request(
    String method,
    String path, {
    String? token,
    // ignore: unused_element_parameter
    Object? body,
    // ignore: unused_element_parameter
    String? version,
  });

  /// People the member may like, best first. [limit] is 1 to 20; the Home strip asks for 12.
  Future<ApiPage<Profile>> possibleMatches(
    Session s, {
    int limit = 20,
    bool excludeFollowing = false,
    String? cursor,
  }) async => ApiPage.fromJson(
    await _request(
      'POST',
      '/v1/discovery/possible-matches',
      token: s.token,
      body: {
        'limit': limit,
        if (excludeFollowing) 'excludeFollowing': true,
        'cursor': ?cursor,
      },
    ) as Map<String, dynamic>,
    Profile.fromJson,
  );

  /// The caller's own gallery, in order.
  Future<Gallery> gallery(Session s) async => Gallery.fromJson(
    await _request('GET', '/v1/me/photos', token: s.token)
        as Map<String, dynamic>,
  );

  /// Adds an uploaded photo (upload it with purpose `avatar`) at the end of the gallery.
  Future<Gallery> addGalleryPhoto(Session s, String mediaId) async =>
      Gallery.fromJson(
        await _request(
          'POST',
          '/v1/me/photos',
          token: s.token,
          body: {'mediaId': mediaId},
        ) as Map<String, dynamic>,
      );

  /// Puts [newMediaId] in the place of [mediaId], keeping its position.
  Future<Gallery> replaceGalleryPhoto(
    Session s,
    String mediaId,
    String newMediaId,
  ) async => Gallery.fromJson(
    await _request(
      'PUT',
      '/v1/me/photos/$mediaId',
      token: s.token,
      body: {'mediaId': newMediaId},
    ) as Map<String, dynamic>,
  );

  Future<Gallery> deleteGalleryPhoto(Session s, String mediaId) async =>
      Gallery.fromJson(
        await _request('DELETE', '/v1/me/photos/$mediaId', token: s.token)
            as Map<String, dynamic>,
      );

  /// Every photo of the gallery, once, in the order wanted; the first becomes the profile photo.
  Future<Gallery> reorderGallery(Session s, List<String> mediaIds) async =>
      Gallery.fromJson(
        await _request(
          'PUT',
          '/v1/me/photos/order',
          token: s.token,
          body: {'mediaIds': mediaIds},
        ) as Map<String, dynamic>,
      );

  /// Who visited [userId]'s profile in the last 30 days, when that member shares it (403 VISITORS_PRIVATE otherwise).
  Future<ApiPage<VisitedPerson>> recentVisitors(
    Session s,
    String userId, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _request(
      'GET',
      '/v1/users/$userId/visitors${_cursorQuery(cursor)}',
      token: s.token,
    ) as Map<String, dynamic>,
    VisitedPerson.fromJson,
  );

  /// The profiles the caller opened in the last 30 days: their own history, nobody else's.
  Future<ApiPage<VisitedPerson>> placesVisited(
    Session s, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _request(
      'GET',
      '/v1/me/visited${_cursorQuery(cursor)}',
      token: s.token,
    ) as Map<String, dynamic>,
    VisitedPerson.fromJson,
  );

  /// Deletes the caller's visit history.
  Future<void> clearPlacesVisited(Session s) async =>
      await _request('DELETE', '/v1/me/visited', token: s.token);
}
