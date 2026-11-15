import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('a birthday has to exist in its month (SIC-092)', () {
    expect(Birthday.tryParse('1985-02-30'), isNull);
    expect(Birthday.tryParse('1985-04-31'), isNull);
    expect(Birthday.tryParse('1985-02-29'), isNull, reason: 'no leap year');
    expect(Birthday.tryParse('1984-02-29')?.day, 29);
    expect(Birthday.tryParse('1985-01-31')?.day, 31);
    expect(Birthday.tryParse('1985-06-30')?.month, 6);
    // Without a year 29 February may be meant.
    expect(Birthday.tryParse('--02-29')?.day, 29);
    expect(Birthday.tryParse('--02-30'), isNull);
    expect(Birthday.tryParse('--11-31'), isNull);
    // As before: nonsense stays out.
    expect(Birthday.tryParse('1985-13-01'), isNull);
    expect(Birthday.tryParse('1985-06-32'), isNull);
    expect(Birthday.tryParse('1985-06-00'), isNull);
    expect(Birthday.tryParse('12.6.1985'), isNull);
  });
}
