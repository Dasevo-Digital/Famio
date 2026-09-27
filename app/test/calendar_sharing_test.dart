import 'dart:convert';

import 'package:famio/src/widgets/calendar_sharing.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SyncEngine engine() {
    final store = LocalStore.open(':memory:')
      ..setMeta(
        'members',
        jsonEncode([
          for (final (id, name) in [
            ('m1', 'Mama'),
            ('p1', 'Papa'),
            ('k1', 'Kind'),
          ])
            FamilyMember(id: id, username: id, displayName: name).toJson(),
        ]),
      );
    return SyncEngine(
      store: store,
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
  }

  test('labels name who sees a calendar', () {
    final e = engine();
    expect(sharingLabel(e, const CalendarSharing.family()), 'Ganze Familie');
    expect(sharingLabel(e, const CalendarSharing.private()), 'Nur ich');
    expect(
      sharingLabel(e, const CalendarSharing.only(['m1', 'p1'])),
      'Ich, Papa',
    );
  });

  testWidgets('the picker chooses family, some members or just me', (
    tester,
  ) async {
    final e = engine();
    var value = const CalendarSharing.family();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => CalendarSharingPicker(
              engine: e,
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      ),
    );
    // Not the owner themselves.
    expect(find.text('Mama'), findsNothing);

    await tester.tap(find.text('Ausgewählte'));
    await tester.pump();
    expect(value.members, unorderedEquals(['p1', 'k1']));

    await tester.tap(find.text('Kind'));
    await tester.pump();
    expect(value, const CalendarSharing.only(['p1']));

    await tester.tap(find.text('Nur ich'));
    await tester.pump();
    expect(value.private, isTrue);
    expect(find.text('Papa'), findsNothing);
  });
}
