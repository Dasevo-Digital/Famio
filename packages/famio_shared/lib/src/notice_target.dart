/// Where a notification leads when tapped (#385): a task, an appointment
/// (one date of it), a chat, a child, an alarm, a day in the calendar, a
/// section or one of its pages. Written as `kind:id`, an appointment's date
/// after an `@` (`event:abc@2026-11-17T09:00:00.000`). The server sends it
/// with its notifications; the apps give it to their own reminders.
///
/// Only something to open: an app that cannot find the entry (deleted, not
/// visible to this member) opens its section, nothing else happens.
class NoticeTarget {
  const NoticeTarget(this.kind, [this.id = '', this.at]);

  const NoticeTarget.task(String id) : this(taskKind, id);

  /// [at]: the date of a repeating appointment, else its next one opens.
  const NoticeTarget.event(String id, [DateTime? at]) : this(eventKind, id, at);

  const NoticeTarget.chat(String chatId) : this(chatKind, chatId);

  const NoticeTarget.child(String id) : this(childKind, id);

  const NoticeTarget.pregnancy(String id) : this(pregnancyKind, id);

  const NoticeTarget.sos(String alertId) : this(sosKind, alertId);

  /// A section by its name in the apps (`location`, `chores`, …).
  const NoticeTarget.section(String name) : this(sectionKind, name);

  /// A page of a section: [devices], [deadlines], [loans], [waste],
  /// [subscriptions].
  const NoticeTarget.page(String name) : this(pageKind, name);

  /// The calendar on that day (only its date counts).
  NoticeTarget.day(DateTime day)
    : this(dayKind, '', DateTime(day.year, day.month, day.day));

  static const taskKind = 'task';
  static const eventKind = 'event';
  static const chatKind = 'chat';
  static const childKind = 'child';
  static const pregnancyKind = 'pregnancy';
  static const sosKind = 'sos';
  static const sectionKind = 'section';
  static const pageKind = 'page';
  static const dayKind = 'day';

  /// The years a date of a target may have; others are left out.
  static const firstYear = 1900;
  static const lastYear = 2200;

  static const devices = 'devices';
  static const deadlines = 'deadlines';
  static const loans = 'loans';
  static const waste = 'waste';
  static const subscriptions = 'subscriptions';

  final String kind;
  final String id;
  final DateTime? at;

  /// Opens Famio at it from another app (ntfy): `famio://open?target=…`.
  String get link => Uri(
    scheme: 'famio',
    host: 'open',
    queryParameters: {'target': encode()},
  ).toString();

  /// The target of a [link], null for any other address.
  static NoticeTarget? fromLink(Uri uri) =>
      uri.scheme == 'famio' && uri.host == 'open'
      ? decode(uri.queryParameters['target'])
      : null;

  String encode() {
    final date = at?.toIso8601String();
    if (date != null) return '$kind:$id@$date';
    return id.isEmpty ? kind : '$kind:$id';
  }

  /// Null for anything else (empty, unknown, broken).
  static NoticeTarget? decode(String? text) {
    if (text == null || text.isEmpty || text.length > 512) return null;
    final colon = text.indexOf(':');
    final kind = colon < 0 ? text : text.substring(0, colon);
    if (!_kinds.contains(kind)) return null;
    var id = colon < 0 ? '' : text.substring(colon + 1);
    DateTime? at;
    // Ids from other calendars may contain an @; only a date after the
    // last one is a date.
    final mark = id.lastIndexOf('@');
    if (mark >= 0) {
      final date = DateTime.tryParse(id.substring(mark + 1));
      if (date != null) {
        // A date far from any calendar's (a link from another app) is
        // none: the calendar would fail on it (#579).
        if (date.year >= firstYear && date.year <= lastYear) at = date;
        id = id.substring(0, mark);
      }
    }
    if (kind == dayKind) return at == null ? null : NoticeTarget.day(at);
    if (id.isEmpty) return null;
    return NoticeTarget(kind, id, at);
  }

  static const _kinds = {
    taskKind,
    eventKind,
    chatKind,
    childKind,
    pregnancyKind,
    sosKind,
    sectionKind,
    pageKind,
    dayKind,
  };

  @override
  bool operator ==(Object other) =>
      other is NoticeTarget &&
      other.kind == kind &&
      other.id == id &&
      other.at == at;

  @override
  int get hashCode => Object.hash(kind, id, at);

  @override
  String toString() => encode();
}
