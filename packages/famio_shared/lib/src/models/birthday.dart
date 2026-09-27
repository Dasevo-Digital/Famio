/// A birthday, possibly without the year ("--MM-DD" as in vCard).
class Birthday {
  const Birthday(this.month, this.day, [this.year]);

  /// Parses "YYYY-MM-DD" or "--MM-DD"; null for anything else.
  static Birthday? tryParse(Object? value) {
    if (value is! String) return null;
    final full = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    final partial = RegExp(r'^--(\d{2})-(\d{2})$').firstMatch(value);
    final (year, month, day) = full != null
        ? (int.parse(full[1]!), int.parse(full[2]!), int.parse(full[3]!))
        : partial != null
        ? (null, int.parse(partial[1]!), int.parse(partial[2]!))
        : (null, 0, 0);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return Birthday(month, day, year);
  }

  factory Birthday.ofDate(DateTime d) => Birthday(d.month, d.day, d.year);

  final int month;
  final int day;
  final int? year;

  /// The birthday in [year] (29 February becomes 28 February).
  DateTime inYear(int year) {
    final last = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, day > last ? last : day);
  }

  /// The next birthday on or after [from] (a date).
  DateTime next(DateTime from) {
    final today = DateTime(from.year, from.month, from.day);
    final thisYear = inYear(today.year);
    return thisYear.isBefore(today) ? inYear(today.year + 1) : thisYear;
  }

  /// Age reached on [date], if the year is known.
  int? ageOn(DateTime date) => year == null ? null : date.year - year!;

  @override
  String toString() {
    String two(int v) => v.toString().padLeft(2, '0');
    return year == null
        ? '--${two(month)}-${two(day)}'
        : '${year.toString().padLeft(4, '0')}-${two(month)}-${two(day)}';
  }

  @override
  bool operator ==(Object other) =>
      other is Birthday &&
      other.month == month &&
      other.day == day &&
      other.year == year;

  @override
  int get hashCode => Object.hash(month, day, year);
}
