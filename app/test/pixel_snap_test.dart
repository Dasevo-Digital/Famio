import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/widgets/famio_glyph.dart';
import 'package:famio/src/widgets/pixel_snap.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  Widget at(double ratio, Offset position, Key key) => MediaQuery(
    data: MediaQueryData(devicePixelRatio: ratio),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.only(left: position.dx, top: position.dy),
          child: PixelSnap(child: SizedBox.square(key: key, dimension: 10)),
        ),
      ),
    ),
  );

  testWidgets('moves the child onto whole device pixels', (tester) async {
    const key = Key('box');
    await tester.pumpWidget(at(1, const Offset(10.5, 20.25), key));
    expect(tester.getTopLeft(find.byKey(key)), const Offset(11, 20));
    // Twice the density: half points are whole pixels already.
    await tester.pumpWidget(at(2, const Offset(10.5, 20.3), key));
    expect(tester.getTopLeft(find.byKey(key)), const Offset(10.5, 20.5));
  });

  testWidgets('the logo of a tall window on a 1x display is sharp', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2704, 980);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tour.offered': true});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    state
      ..me = me
      ..engine = SyncEngine(
        store: LocalStore.open(':memory:'),
        api: FamioApiClient('localhost:1'),
        memberId: me.id,
      );
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    bool whole(Offset o) =>
        o.dx == o.dx.roundToDouble() && o.dy == o.dy.roundToDouble();
    expect(whole(tester.getTopLeft(find.byType(FamioGlyph).first)), isTrue);
    expect(whole(tester.getTopLeft(find.text('Famio').first)), isTrue);
    expect(whole(tester.getTopLeft(find.text('Kalender').first)), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });
}
