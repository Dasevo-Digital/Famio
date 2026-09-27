import '../sync_record.dart';

/// A lesson in a [Timetable].
class Lesson {
  const Lesson({
    required this.weekday,
    required this.period,
    required this.subject,
    this.room = '',
  });

  factory Lesson.fromJson(Map<String, Object?> json) => Lesson(
    weekday: (json['day'] as num).toInt(),
    period: (json['p'] as num).toInt(),
    subject: json['subject'] as String? ?? '',
    room: json['room'] as String? ?? '',
  );

  /// 1 = Monday … 5 = Friday.
  final int weekday;

  /// Index into [Timetable.periods].
  final int period;
  final String subject;
  final String room;

  Map<String, Object?> toJson() => {
    'day': weekday,
    'p': period,
    'subject': subject,
    if (room.isNotEmpty) 'room': room,
  };
}

/// School times: start and end of each lesson ("08:00").
class Period {
  const Period(this.start, this.end);

  final String start;
  final String end;
}

/// A child's school timetable, stored in `Collections.timetables` (record
/// id = child id).
class Timetable {
  const Timetable({
    required this.childId,
    this.periods = defaultPeriods,
    this.lessons = const [],
    this.school = '',
  });

  static const defaultPeriods = [
    Period('08:00', '08:45'),
    Period('08:50', '09:35'),
    Period('09:55', '10:40'),
    Period('10:45', '11:30'),
    Period('11:45', '12:30'),
    Period('12:35', '13:20'),
    Period('13:30', '14:15'),
    Period('14:20', '15:05'),
  ];

  factory Timetable.fromRecord(SyncRecord r) => Timetable(
    childId: r.id,
    periods: (r.data['periods'] as List?)?.isNotEmpty == true
        ? [
            for (final p in r.data['periods'] as List)
              Period((p as Map)['start'] as String, p['end'] as String),
          ]
        : defaultPeriods,
    lessons: [
      for (final l in r.data['lessons'] as List? ?? const [])
        Lesson.fromJson((l as Map).cast()),
    ],
    school: r.data['school'] as String? ?? '',
  );

  final String childId;
  final List<Period> periods;
  final List<Lesson> lessons;
  final String school;

  Lesson? lesson(int weekday, int period) => lessons
      .where((l) => l.weekday == weekday && l.period == period)
      .firstOrNull;

  /// Lessons of [weekday] in order.
  List<Lesson> day(int weekday) =>
      lessons.where((l) => l.weekday == weekday).toList()
        ..sort((a, b) => a.period.compareTo(b.period));

  /// End of the last lesson on [weekday] ("12:30"), if any.
  String? endOf(int weekday) {
    final d = day(weekday);
    if (d.isEmpty || d.last.period >= periods.length) return null;
    return periods[d.last.period].end;
  }

  Timetable copyWith({
    List<Period>? periods,
    List<Lesson>? lessons,
    String? school,
  }) => Timetable(
    childId: childId,
    periods: periods ?? this.periods,
    lessons: lessons ?? this.lessons,
    school: school ?? this.school,
  );

  /// Sets or clears (empty subject) one lesson.
  Timetable withLesson(
    int weekday,
    int period,
    String subject, [
    String room = '',
  ]) => copyWith(
    lessons: [
      for (final l in lessons)
        if (l.weekday != weekday || l.period != period) l,
      if (subject.trim().isNotEmpty)
        Lesson(
          weekday: weekday,
          period: period,
          subject: subject.trim(),
          room: room.trim(),
        ),
    ],
  );

  Map<String, Object?> toData() => {
    'periods': [
      for (final p in periods) {'start': p.start, 'end': p.end},
    ],
    'lessons': [for (final l in lessons) l.toJson()],
    'school': school,
  };
}
