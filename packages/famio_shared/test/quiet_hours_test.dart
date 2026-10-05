import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('over midnight', () {
    const q = QuietHours(enabled: true, start: 21 * 60, end: 7 * 60);
    expect(q.isQuietAt(DateTime(2026, 10, 5, 20, 59)), isFalse);
    expect(q.isQuietAt(DateTime(2026, 10, 5, 21)), isTrue);
    expect(q.isQuietAt(DateTime(2026, 10, 6, 3)), isTrue);
    expect(q.isQuietAt(DateTime(2026, 10, 6, 7)), isFalse);
  });

  test('within a day, switched off, empty', () {
    const q = QuietHours(enabled: true, start: 13 * 60, end: 15 * 60);
    expect(q.isQuietAt(DateTime(2026, 10, 5, 14)), isTrue);
    expect(q.isQuietAt(DateTime(2026, 10, 5, 16)), isFalse);
    expect(
      q.copyWith(enabled: false).isQuietAt(DateTime(2026, 10, 5, 14)),
      isFalse,
    );
    expect(
      q.copyWith(end: 13 * 60).isQuietAt(DateTime(2026, 10, 5, 13)),
      isFalse,
    );
  });

  test('JSON with "HH:MM", invalid values fall back', () {
    final q = QuietHours.fromJson(const {
      'enabled': true,
      'start': '22:30',
      'end': '06:15',
      'placesLoud': false,
    });
    expect((q.start, q.end, q.placesLoud), (22 * 60 + 30, 6 * 60 + 15, false));
    expect(QuietHours.fromJson(q.toJson()).toJson(), q.toJson());
    expect(QuietHours.fromJson(const {'start': '25:00'}).start, 21 * 60);
  });
}
