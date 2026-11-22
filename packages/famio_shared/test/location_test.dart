import 'dart:convert';

import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('a position report with numbers that are none is refused', () {
    LocationFix parse(String json) =>
        LocationFix.fromJson((jsonDecode(json) as Map).cast());
    final ok = parse(
      '{"lat":53.56,"lon":9.98,"acc":10,"at":1793000000000,"battery":40}',
    );
    expect(ok.at.millisecondsSinceEpoch, 1793000000000);
    expect(ok.battery, 40);
    // JSON allows 1e400 (infinity) and times no date has.
    for (final json in [
      '{"lat":53.56,"lon":9.98,"at":1e400}',
      '{"lat":53.56,"lon":9.98,"at":-1e400}',
      '{"lat":53.56,"lon":9.98,"at":1e300}',
      '{"lat":53.56,"lon":9.98,"at":1793000000000,"battery":1e400}',
    ]) {
      expect(() => parse(json), throwsFormatException, reason: json);
    }
    // A level no battery has is left out.
    expect(
      parse(
        '{"lat":53.56,"lon":9.98,"at":1793000000000,"battery":250}',
      ).battery,
      isNull,
    );
    // A position that is none is kept out by [LocationFix.valid].
    expect(parse('{"lat":1e400,"lon":9.98,"at":1793000000000}').valid, isFalse);
  });

  test('another sharing device of the member is kept', () {
    const l = MemberLocation(
      memberId: 'm',
      state: SharingState.active,
      device: 'iPhone',
      otherDevice: 'iPad',
    );
    final back = MemberLocation.fromRecord(
      SyncRecord(
        collection: Collections.memberLocations,
        id: 'm',
        data: l.toData(),
        updatedAt: 0,
      ),
    );
    expect(back.otherDevice, 'iPad');
    expect(back.withOtherDevice(null).toData(), isNot(contains('otherDevice')));
    expect(back.withOtherDevice(null).device, 'iPhone');
  });
}
