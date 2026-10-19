import 'package:sqlite3/sqlite3.dart';

/// Properties calendar apps set on a calendar with PROPPATCH: colour,
/// order, name or description, kept per member (RFC 4918 "dead"
/// properties). Without them a PROPFIND answers the defaults again, and
/// Apple Calendar sends its values anew on every refresh while the
/// member's own colour is lost.
class DavProperties {
  DavProperties(Database db) : _db = db;

  DavProperties._none() : _db = null;

  /// Keeps nothing (tests and tools without a database).
  static final none = DavProperties._none();

  final Database? _db;

  /// Longer values are not kept (a colour or a name is a few characters).
  static const maxValue = 2048;

  /// More properties per calendar are not kept.
  static const maxPerCalendar = 32;

  /// The kept properties of [memberId] on the calendar [slug]:
  /// (namespace, name) → text.
  Map<(String, String), String> of(String memberId, String slug) {
    final db = _db;
    if (db == null) return const {};
    return {
      for (final row in db.select(
        'SELECT ns, name, value FROM dav_props'
        ' WHERE member_id = ? AND calendar = ?',
        [memberId, slug],
      ))
        (row['ns'] as String, row['name'] as String): row['value'] as String,
    };
  }

  /// Keeps [value]; false if it was too long or there are too many.
  bool set(String memberId, String slug, (String, String) name, String value) {
    final db = _db;
    if (db == null || value.length > maxValue) return false;
    final (ns, local) = name;
    final known = of(memberId, slug);
    if (!known.containsKey(name) && known.length >= maxPerCalendar) {
      return false;
    }
    db.execute(
      'INSERT INTO dav_props (member_id, calendar, ns, name, value)'
      ' VALUES (?, ?, ?, ?, ?)'
      ' ON CONFLICT DO UPDATE SET value = excluded.value',
      [memberId, slug, ns, local, value],
    );
    return true;
  }

  void remove(String memberId, String slug, (String, String) name) {
    final (ns, local) = name;
    _db?.execute(
      'DELETE FROM dav_props'
      ' WHERE member_id = ? AND calendar = ? AND ns = ? AND name = ?',
      [memberId, slug, ns, local],
    );
  }
}
