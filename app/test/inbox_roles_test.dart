import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/inbox_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

const _letter = FileRef(
  id: 'f1',
  name: 'arztbrief.pdf',
  mime: 'application/pdf',
  size: 4,
);

/// The family inbox: no empty entries, children only see what is shared
/// with them, documents are filed with a category and an audience, and a
/// deleted entry comes back with "Rückgängig" (GRU-074, -079, -082, -084).
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late SyncEngine engine;

  Future<void> open(WidgetTester tester, {String me = 'm1'}) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: me,
    );
    state
      ..me = engine.members.firstWhere((m) => m.id == me)
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    Navigator.of(
      tester.element(find.byType(Scaffold).first),
    ).push(MaterialPageRoute<void>(builder: (_) => const InboxScreen()));
    await tester.pumpAndSettle();
  }

  Finder save() => find.widgetWithText(FilledButton, tr.commonSave);

  testWidgets('nothing typed is no entry', (tester) async {
    await open(tester);
    await tester.tap(find.byType(AddButton));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save()).onPressed, isNull);
    await tester.tap(save());
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(engine.inboxItems, isEmpty);
    await tester.enterText(find.byType(TextField).at(1), 'Zettel vom Kiga');
    await tester.pump();
    expect(tester.widget<FilledButton>(save()).onPressed, isNotNull);
    await tester.tap(save());
    await tester.pumpAndSettle();
    expect(engine.inboxItems.single.title, 'Zettel vom Kiga');
    expect(engine.inboxItems.single.forChildren, isFalse);
  });

  testWidgets('shared with the children only when switched on', (tester) async {
    await open(tester);
    await tester.tap(find.byType(AddButton));
    await tester.pumpAndSettle();
    final children = find.widgetWithText(SwitchListTile, tr.inboxForChildren);
    expect(tester.widget<SwitchListTile>(children).value, isFalse);
    await tester.enterText(find.byType(TextField).first, 'Ausflug Zoo');
    await tester.tap(children);
    await tester.pump();
    await tester.tap(save());
    await tester.pumpAndSettle();
    expect(engine.inboxItems.single.forChildren, isTrue);
    expect(
      engine.record(Collections.inbox, engine.inboxItems.single.id)!.data,
      containsPair(InboxItem.forChildrenKey, true),
    );
  });

  testWidgets('without other children there is nothing to share', (
    tester,
  ) async {
    await open(tester, me: 'k1');
    await tester.tap(find.byType(AddButton));
    await tester.pumpAndSettle();
    expect(find.text(tr.inboxForChildren), findsNothing);
  });

  testWidgets('a deleted entry comes back', (tester) async {
    await open(tester);
    engine.saveInboxItem(
      InboxItem(id: 'e1', title: 'Rechnung', createdAt: DateTime(2026, 11, 1)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(tr.inboxFileAs));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr.commonDelete).last);
    await tester.pumpAndSettle();
    expect(engine.inboxItems, isEmpty);
    expect(find.text(tr.undoWhatDeleted('Rechnung')), findsOneWidget);
    await tester.tap(find.text(tr.commonUndo));
    await tester.pumpAndSettle();
    expect(engine.inboxItems.single.title, 'Rechnung');
  });

  Future<void> fileAsDocument(WidgetTester tester) async {
    await tester.tap(find.byTooltip(tr.inboxFileAs));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr.commonDocument).last);
    await tester.pumpAndSettle();
    expect(find.text(tr.inboxDocumentTitle), findsOneWidget);
  }

  Object? chosen(WidgetTester tester) => tester
      .widget<RadioGroup<Object?>>(
        find.byWidgetPredicate((w) => w is RadioGroup),
      )
      .groupValue;

  Object? valueOf(WidgetTester tester, String title) => tester
      .widget<RadioListTile<Object?>>(
        find.ancestor(
          of: find.text(title),
          matching: find.byWidgetPredicate((w) => w is RadioListTile),
        ),
      )
      .value;

  testWidgets('a letter is filed with a category for the adults', (
    tester,
  ) async {
    await open(tester);
    engine.saveInboxItem(
      const InboxItem(
        id: 'e2',
        title: 'Arztbrief',
        files: [_letter],
        createdBy: 'm1',
      ),
    );
    await tester.pumpAndSettle();
    await fileAsDocument(tester);
    // Not shared with the children in the inbox: not as a document either.
    expect(chosen(tester), valueOf(tester, tr.inboxDocumentAdults));
    await tester.tap(find.text(DocumentCategory.health.label));
    await tester.pumpAndSettle();
    // A health letter starts out as the author's, as in the editor.
    expect(chosen(tester), valueOf(tester, tr.docsOnlyMe));
    await tester.tap(find.text(tr.inboxDocumentAdults));
    await tester.pumpAndSettle();
    await tester.tap(save());
    await tester.pumpAndSettle();
    final doc = engine.documents.single;
    expect(doc.category, DocumentCategory.health);
    expect(doc.visibleTo, unorderedEquals(['m1', 'm2']));
    expect(doc.file?.id, 'f1');
    expect(engine.inboxItems, isEmpty);
  });

  testWidgets('one shared with the children goes to the family', (
    tester,
  ) async {
    await open(tester);
    engine.saveInboxItem(
      const InboxItem(
        id: 'e3',
        title: 'Elternbrief',
        files: [_letter],
        forChildren: true,
      ),
    );
    await tester.pumpAndSettle();
    await fileAsDocument(tester);
    expect(chosen(tester), valueOf(tester, tr.commonWholeFamily));
    await tester.tap(find.text(DocumentCategory.school.label));
    await tester.pumpAndSettle();
    await tester.tap(save());
    await tester.pumpAndSettle();
    final doc = engine.documents.single;
    expect(doc.category, DocumentCategory.school);
    expect(doc.visibleTo, isNull);
  });

  testWidgets('cancelled, the entry stays in the inbox', (tester) async {
    await open(tester);
    engine.saveInboxItem(
      const InboxItem(id: 'e4', title: 'Scan', files: [_letter]),
    );
    await tester.pumpAndSettle();
    await fileAsDocument(tester);
    await tester.tap(find.text(tr.commonCancel));
    await tester.pumpAndSettle();
    expect(engine.documents, isEmpty);
    expect(engine.inboxItems, hasLength(1));
  });

  Future<void> fileAs(WidgetTester tester, String what) async {
    await tester.tap(find.byTooltip(tr.inboxFileAs));
    await tester.pumpAndSettle();
    await tester.tap(find.text(what).last);
    await tester.pumpAndSettle();
  }

  testWidgets('a task or note keeps it from the children', (tester) async {
    await open(tester);
    engine.saveInboxItem(
      const InboxItem(id: 'e5', title: 'Rezept abholen', createdBy: 'm1'),
    );
    await tester.pumpAndSettle();
    await fileAs(tester, tr.commonTask);
    expect(engine.tasks.single.visibleTo, unorderedEquals(['m1', 'm2']));
    engine.saveInboxItem(
      const InboxItem(id: 'e6', title: 'Impfpass', createdBy: 'k1'),
    );
    await tester.pumpAndSettle();
    await fileAs(tester, tr.commonNote);
    // A child who filed it keeps it.
    expect(engine.notes.single.visibleTo, unorderedEquals(['m1', 'm2', 'k1']));
    expect(engine.inboxItems, isEmpty);
  });

  testWidgets('shared with the children, a task goes to the family', (
    tester,
  ) async {
    await open(tester);
    engine.saveInboxItem(
      const InboxItem(id: 'e7', title: 'Turnbeutel', forChildren: true),
    );
    await tester.pumpAndSettle();
    await fileAs(tester, tr.commonTask);
    expect(engine.tasks.single.visibleTo, isNull);
  });

  testWidgets('an appointment not shared with the children is private', (
    tester,
  ) async {
    await open(tester);
    engine.saveInboxItem(
      const InboxItem(id: 'e8', title: 'Kardiologie', createdBy: 'm1'),
    );
    await tester.pumpAndSettle();
    await fileAs(tester, tr.commonEvent);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    // Appointments have no audience: the children see "Belegt".
    expect(engine.events.single.confidential, isTrue);
  });
}
