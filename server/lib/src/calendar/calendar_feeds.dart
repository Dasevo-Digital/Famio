import 'dart:convert';
import 'dart:math';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import '../api_exception.dart';

/// Private ICS addresses of members. The random token in the URL is the only
/// credential (calendar apps cannot log in), so it can be revoked per feed.
class CalendarFeeds {
  CalendarFeeds(this._db);

  final Database _db;
  final _random = Random.secure();

  List<CalendarFeed> forUser(String userId) => [
    for (final row in _db.select(
      'SELECT * FROM calendar_feeds WHERE user_id = ? ORDER BY created_at',
      [userId],
    ))
      _feed(row),
  ];

  CalendarFeed create(
    String userId, {
    required String name,
    required FeedScope scope,
    bool hideDetails = false,
  }) {
    name = name.trim();
    if (name.isEmpty) {
      throw ApiException.badRequest(
        'invalid_name',
        'Bitte einen Namen angeben',
      );
    }
    final id = newId();
    final token = base64Url
        .encode(List<int>.generate(24, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    _db.execute(
      'INSERT INTO calendar_feeds'
      ' (id, token, user_id, name, scope, hide_details, created_at)'
      ' VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        token,
        userId,
        name,
        scope.name,
        hideDetails ? 1 : 0,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return forUser(userId).firstWhere((f) => f.id == id);
  }

  void delete(String userId, String id) {
    _db.execute('DELETE FROM calendar_feeds WHERE id = ? AND user_id = ?', [
      id,
      userId,
    ]);
  }

  /// The feed (and its owner) for a token from a feed URL.
  (CalendarFeed, String userId)? byToken(String token) {
    final rows = _db.select('SELECT * FROM calendar_feeds WHERE token = ?', [
      token,
    ]);
    if (rows.isEmpty) return null;
    return (_feed(rows.first), rows.first['user_id'] as String);
  }

  static CalendarFeed _feed(Row row) => CalendarFeed(
    id: row['id'] as String,
    name: row['name'] as String,
    scope: FeedScope.values.byName(row['scope'] as String),
    path: 'ical/${row['token']}.ics',
    hideDetails: row['hide_details'] == 1,
  );
}
