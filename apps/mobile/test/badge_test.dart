import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';

void main() {
  group('badgeLabel', () {
    test('is exact up to 99 and 99+ after', () {
      expect(badgeLabel(0), '0');
      expect(badgeLabel(7), '7');
      expect(badgeLabel(99), '99');
      expect(badgeLabel(100), '99+');
      expect(badgeLabel(99, more: true), '99+');
      expect(badgeLabel(3, more: true), '99+');
    });
  });

  group('UnreadBadge', () {
    test('reads the capped count and the more flag', () {
      final b = UnreadBadge.fromJson({'unreadCount': 99, 'unreadMore': true});
      expect(b.count, 99);
      expect(b.more, isTrue);
      expect(b.label, '99+');
    });

    test('an older server has no flag and no count', () {
      expect(UnreadBadge.fromJson({'unreadCount': 12}).label, '12');
      expect(UnreadBadge.fromJson({}).label, '0');
    });
  });

  group('Story views', () {
    Map<String, dynamic> json({int? views, bool? more}) => {
      'storyId': 's1',
      'body': 'hi',
      'background': 'sunrise',
      'textStyle': 'clean',
      'media': null,
      'audience': 'followers',
      'createdAt': '2026-10-14T10:00:00Z',
      'expiresAt': '2026-10-15T10:00:00Z',
      'seen': false,
      'viewCount': ?views,
      'viewCountMore': ?more,
    };

    test('shows the count, and 99+ when the server says more', () {
      expect(Story.fromJson(json(views: 4)).viewsLabel, '4');
      expect(Story.fromJson(json()).viewsLabel, '0');
      final many = Story.fromJson(json(views: 99, more: true));
      expect(many.viewCountMore, isTrue);
      expect(many.viewsLabel, '99+');
    });
  });
}
