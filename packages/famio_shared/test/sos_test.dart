import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  const mama = FamilyMember(id: 'mama', username: 'mama', displayName: 'Mama');
  const papa = FamilyMember(id: 'papa', username: 'papa', displayName: 'Papa');
  const adults = [mama, papa];

  test('the button calls the first adult with a number by default', () {
    const s = SosSettings(phones: {'papa': '0170 2'});
    expect(s.callMember('mia', adults), 'papa');
    expect(s.callNumber('mia', adults), '0170 2');
    expect(const SosSettings().callNumber('mia', adults), isNull);
  });

  test('parents choose per member: someone, 112 or no call', () {
    const s = SosSettings(
      phones: {'mama': '0170 1', 'papa': '0170 2'},
      call: {'mia': 'papa', 'ben': SosSettings.emergency, 'lea': 'none'},
    );
    expect(s.callNumber('mia', adults), '0170 2');
    expect(s.callNumber('ben', adults), '112');
    expect(s.callNumber('lea', adults), isNull);
    // Mama's own button never calls herself.
    expect(s.callNumber('mama', adults), '0170 2');
    // The called parent gets the text first, then the others.
    expect(s.smsNumbers('mia', adults), ['0170 2', '0170 1']);
  });

  test('settings and alerts survive the round trip', () {
    final s = SosSettings.fromRecord(
      SyncRecord(
        collection: Collections.sosSettings,
        id: SosSettings.recordId,
        data: const SosSettings(
          siren: false,
          phones: {'mama': '0170 1', 'leer': ' '},
        ).toData(),
        updatedAt: 1,
      ),
    );
    expect(s.siren, isFalse);
    expect(s.sms, isTrue);
    expect(s.phones, {'mama': '0170 1'});

    final a = SosAlert(
      id: 'a',
      memberId: 'mia',
      startedAt: DateTime.utc(2026, 10, 6, 14),
      latitude: 53.55,
      longitude: 10,
      state: SosState.coming,
      comingBy: 'mama',
    );
    final back = SosAlert.fromRecord(
      SyncRecord(
        collection: Collections.sosAlerts,
        id: 'a',
        data: a.toData(),
        updatedAt: 1,
      ),
    );
    expect(
      (back.state, back.comingBy, back.open),
      (SosState.coming, 'mama', true),
    );
    expect(back.mapLink, contains('mlat=53.550000&mlon=10.000000'));
  });
}
