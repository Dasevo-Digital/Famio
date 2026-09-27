import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/screens/location_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  const me = FamilyMember(
    id: 'm1',
    username: 'mama',
    displayName: 'Mama',
    isAdmin: true,
  );
  late SyncEngine engine;

  SyncRecord serverRecord(
    String collection,
    String id,
    Map<String, Object?> data,
  ) => SyncRecord(
    collection: collection,
    id: id,
    data: data,
    updatedAt: 1,
    rev: 1,
  );

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    final now = DateTime.now();
    final store = LocalStore.open(':memory:')
      ..setMeta(
        'members',
        '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
            '{"id":"m2","username":"mia","displayName":"Mia"},'
            '{"id":"m3","username":"papa","displayName":"Papa"}]',
      );
    for (final r in [
      serverRecord(
        Collections.places,
        'school',
        const Place(
          id: 'school',
          name: 'Schule',
          latitude: 53.575,
          longitude: 9.995,
        ).toData(),
      ),
      serverRecord(
        Collections.memberLocations,
        'm2',
        MemberLocation(
          memberId: 'm2',
          state: SharingState.active,
          latitude: 53.5751,
          longitude: 9.9951,
          accuracy: 12,
          at: now,
          lastContact: now,
          placeId: 'school',
          placeSince: DateTime(now.year, now.month, now.day, 8, 2),
          battery: 64,
        ).toData(),
      ),
      serverRecord(
        Collections.memberLocations,
        'm3',
        MemberLocation(
          memberId: 'm3',
          state: SharingState.paused,
          latitude: 53.56,
          longitude: 9.98,
          lastContact: now,
        ).toData(),
      ),
    ]) {
      store.put(r, dirty: false);
    }
    engine = SyncEngine(
      store: store,
      api: FamioApiClient('localhost:1'),
      memberId: me.id,
    );
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.tap(find.text('Standort').first);
    await tester.pumpAndSettle();
  }

  testWidgets('family map lists who is where', (tester) async {
    await open(tester);
    expect(find.text('Wo ist wer?'), findsOneWidget);
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.textContaining('Bei „Schule“ seit 08:02'), findsOneWidget);
    expect(find.textContaining('64 % Akku'), findsOneWidget);
    expect(find.text('Pausiert'), findsOneWidget);
    expect(find.text('Teilt keinen Standort'), findsOneWidget);
    // On the desktop only the others are shown.
    expect(find.textContaining('Android oder iPhone'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('places are created on the map', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Orte'));
    await tester.pumpAndSettle();
    expect(find.text('Schule'), findsWidgets);
    await tester.tap(find.text('Ort'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Kita');
    // Without a position it is not saved.
    await tester.tap(find.text('Speichern'));
    await tester.pump();
    expect(find.textContaining('auf die Karte tippen'), findsOneWidget);

    await tester.tap(find.byType(FlutterMap));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    final kita = engine.places.firstWhere((p) => p.name == 'Kita');
    expect(kita.radius, Place.defaultRadius);
    expect(kita.notifyMemberIds, [me.id]);
    await tester.pump(const Duration(seconds: 1));
  });

  test('status texts', () {
    final now = DateTime(2026, 10, 5, 12);
    expect(sharingLabel(null, null, now: now), 'Teilt keinen Standort');
    expect(
      sharingLabel(
        MemberLocation(
          memberId: 'x',
          state: SharingState.active,
          latitude: 1,
          longitude: 1,
          at: now.subtract(const Duration(minutes: 7)),
          lastContact: now.subtract(const Duration(minutes: 2)),
        ),
        null,
        now: now,
      ),
      'Unterwegs · vor 2 Min.',
    );
    expect(
      sharingLabel(
        MemberLocation(
          memberId: 'x',
          state: SharingState.active,
          lastContact: now.subtract(const Duration(hours: 3)),
        ),
        null,
        now: now,
      ),
      'Keine Verbindung seit vor 3 Std.',
    );
    expect(
      sharingLabel(
        MemberLocation(
          memberId: 'x',
          state: SharingState.paused,
          pausedUntil: DateTime(2026, 10, 5, 15, 30),
        ),
        null,
        now: now,
      ),
      'Pausiert bis 15:30 Uhr',
    );
    expect(
      sharingLabel(
        const MemberLocation(memberId: 'x', state: SharingState.off),
        null,
        now: now,
      ),
      'Standort am Handy ausgeschaltet',
    );
  });
}
