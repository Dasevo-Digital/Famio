import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

/// Children switch "Privat" only for appointments they entered (#416);
/// who wrote one last does not count.
void main() {
  SyncEngine engine(String memberId, LocalStore store) => SyncEngine(
    store: store,
    api: FamioApiClient('localhost:1'),
    memberId: memberId,
  );

  CalendarEvent appointment(String id, List<String> members) => CalendarEvent(
    id: id,
    title: 'Arzt',
    start: DateTime(2026, 12, 1, 10),
    end: DateTime(2026, 12, 1, 11),
    memberIds: members,
  );

  test('a new appointment notes who entered it, a change keeps it', () {
    final store = LocalStore.open(':memory:')..setMeta('members', _members);
    final mia = engine('k1', store);
    mia.saveEvent(appointment('own', ['k1']));
    expect(
      mia.record(Collections.events, 'own')!.data[CalendarEvent.createdByKey],
      'k1',
    );
    expect(mia.mayChangeConfidential(appointment('own', ['k1'])), isTrue);

    final mama = engine('m1', store);
    mama.saveEvent(appointment('own', ['k1']).copyWith(title: 'Zahnarzt'));
    expect(
      mama.record(Collections.events, 'own')!.data[CalendarEvent.createdByKey],
      'k1',
    );
  });

  test('a change by the child does not make it the child\'s', () {
    final store = LocalStore.open(':memory:')..setMeta('members', _members);
    engine('m1', store).saveEvent(appointment('therapy', ['k1']));
    final mia = engine('k1', store);
    mia.saveEvent(appointment('therapy', ['k1']).copyWith(notes: 'Hefte'));
    expect(mia.record(Collections.events, 'therapy')!.updatedBy, 'k1');
    expect(mia.mayChangeConfidential(appointment('therapy', ['k1'])), isFalse);
    // New ones stay the child's to mark.
    expect(mia.mayChangeConfidential(null), isTrue);
  });
}
