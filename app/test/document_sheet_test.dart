import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/documents_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// HAU-121, #484: the sheet of a document with long notes scrolls, and its
/// buttons stay on a phone's screen, also at twice the text size.
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  for (final scale in [1.0, 2.0]) {
    testWidgets('long notes at text size $scale', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      SharedPreferences.setMockInitialValues({'tour.offered': true});
      FlutterSecureStorage.setMockInitialValues({});
      final state = AppState();
      await state.init();
      final engine = SyncEngine(
        store: LocalStore.open(':memory:')..setMeta('members', '[]'),
        api: FamioApiClient('localhost:1'),
        memberId: 'm1',
      );
      state
        ..me = const FamilyMember(
          id: 'm1',
          username: 'mama',
          displayName: 'Mama',
        )
        ..engine = engine;
      engine.saveDocument(
        FamilyDocument(
          id: 'd1',
          title: 'Lange Notiz',
          category: DocumentCategory.other,
          file: null,
          notes: [
            for (var i = 1; i <= 45; i++) 'Zeile $i der Notiz',
          ].join('\n'),
        ),
      );
      await tester.pumpWidget(FamioApp(state: state));
      await tester.pump();
      Navigator.of(
        tester.element(find.byType(Scaffold).first),
      ).push(MaterialPageRoute<void>(builder: (_) => const DocumentsScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lange Notiz'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(BottomSheet), findsOneWidget);
      for (final label in [tr.commonEdit, tr.commonDelete]) {
        expect(
          find.text(label).hitTestable(),
          findsOneWidget,
          reason: '"$label" on screen',
        );
      }
      final sheet = tester.getRect(find.byType(BottomSheet));
      expect(sheet.bottom, lessThanOrEqualTo(844));
      // The notes scroll to their end, the buttons stay.
      final notes = find.textContaining('Zeile 45 der Notiz');
      await tester.dragUntilVisible(
        notes,
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(SingleChildScrollView),
        ),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text(tr.commonDelete).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
