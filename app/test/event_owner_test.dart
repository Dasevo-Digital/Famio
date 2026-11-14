import 'dart:async';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/screens/event_editor.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

/// Children switch "Privat" only for appointments they entered (#416);
/// who wrote one last does not count. In others they take only themselves
/// out.
void main() {
  setUpAll(() => initializeDateFormatting('de'));
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

  test('children take others out only of their own appointments', () {
    final store = LocalStore.open(':memory:')..setMeta('members', _members);
    engine('m1', store).saveEvent(appointment('parents', ['m1', 'k1']));
    final mia = engine('k1', store);
    mia.saveEvent(appointment('own', ['k1', 'm1']));
    expect(mia.mayRemoveParticipants(appointment('parents', [])), isFalse);
    expect(mia.mayRemoveParticipants(appointment('own', [])), isTrue);
    expect(mia.mayRemoveParticipants(null), isTrue);
    expect(
      engine('m1', store).mayRemoveParticipants(appointment('own', [])),
      isTrue,
    );
  });

  testWidgets('the editor keeps the others in an appointment of the parents', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final store = LocalStore.open(':memory:')..setMeta('members', _members);
    engine('m1', store).saveEvent(appointment('parents', ['m1', 'k1']));
    final mia = engine('k1', store)
      ..saveEvent(appointment('own', ['k1', 'm1']));
    final state = AppState();
    await state.init();
    state
      ..me = mia.members.last
      ..engine = mia;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    final context = tester.element(find.byType(Scaffold).first);

    Future<Map<String, bool>> chips(String id) async {
      final event = mia.events.firstWhere((e) => e.id == id);
      unawaited(
        showEventEditor(
          context,
          occurrence: Occurrence(event, event.start, event.end),
        ),
      );
      await tester.pumpAndSettle();
      final result = {
        for (final name in ['Mama', 'Mia', 'Ganze Familie'])
          name: _selectable(
            tester.widget(
              find.ancestor(
                of: find.text(name),
                matching: find.byWidgetPredicate(
                  (w) => w is FilterChip || w is ChoiceChip,
                ),
              ),
            ),
          ),
      };
      Navigator.of(tester.element(find.text('Mia').first)).pop();
      await tester.pumpAndSettle();
      return result;
    }

    expect(await chips('parents'), {
      'Mama': false,
      'Mia': true,
      'Ganze Familie': false,
    });
    expect(await chips('own'), {
      'Mama': true,
      'Mia': true,
      'Ganze Familie': true,
    });
  });
}

bool _selectable(Widget chip) =>
    (chip as SelectableChipAttributes).onSelected != null;
