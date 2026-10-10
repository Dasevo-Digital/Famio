import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/search.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/design/theme.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio/src/screens/documents_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  SyncEngine engineWithArchive() {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    // As the server writes it from PaperBuddy.
    engine.store.put(
      SyncRecord(
        collection: Collections.externalDocuments,
        id: 'pb-11',
        data: FamilyDocument(
          id: 'pb-11',
          title: 'Kfz-Versicherung',
          category: DocumentCategory.insurance,
          file: const FileRef(
            id: 'pb-11.20260201',
            name: 'scan.pdf',
            mime: 'application/pdf',
            size: 0,
          ),
          notes: 'HUK-Coburg · Kündigungsfrist',
          expiresAt: DateTime.now().add(const Duration(days: 30)),
          source: 'paperbuddy',
        ).toData(),
        updatedAt: 1,
      ),
      dirty: false,
    );
    return engine;
  }

  test('archive documents count like own ones: search and reminders', () {
    final engine = engineWithArchive();
    final doc = engine.documents.single;
    expect((doc.title, doc.fromArchive), ('Kfz-Versicherung', true));
    expect(
      searchFamily(
        engine,
        'huk',
        sections: {FamioSection.documents},
      ).map((h) => h.title),
      contains('Kfz-Versicherung'),
    );
    final now = DateTime.now();
    expect(
      familyReminders(
        engine,
        from: now,
        to: now.add(const Duration(days: 40)),
      ).where((r) => r.key.startsWith('doc:pb-11')),
      isNotEmpty,
    );
  });

  testWidgets('shown read-only, with where it comes from', (tester) async {
    final engine = engineWithArchive();
    final state = AppState()..engine = engine;
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: famioTheme(Brightness.light),
          home: const DocumentsScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Versicherungen · PaperBuddy'), findsOneWidget);
    await tester.tap(find.text('Kfz-Versicherung'));
    await tester.pumpAndSettle();
    expect(
      find.text('Aus PaperBuddy: Ablage und Änderungen dort.'),
      findsOneWidget,
    );
    expect(find.text('Öffnen'), findsOneWidget);
    expect(find.text('Bearbeiten'), findsNothing);
    expect(find.text('Löschen'), findsNothing);
  });
}
