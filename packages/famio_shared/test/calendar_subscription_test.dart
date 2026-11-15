import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('who may change a calendar subscription (KAL-128)', () {
    const family = CalendarSubscription(
      id: 'ferien',
      name: 'Schulferien',
      url: 'https://ferien.example.com/ferien.ics',
    );
    const own = CalendarSubscription(
      id: 'fussball',
      name: 'Fußball',
      url: 'https://verein.example.com/fussball.ics',
      ownerId: 'kid',
    );
    // The family's: only adults.
    expect(family.editableBy('mama', adult: true), isTrue);
    expect(family.editableBy('kid', adult: false), isFalse);
    // One with an owner: only the owner, child or not.
    expect(own.editableBy('kid', adult: false), isTrue);
    expect(own.editableBy('mama', adult: true), isFalse);
  });
}
