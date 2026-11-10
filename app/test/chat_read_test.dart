// Only messages somebody can see count as read: a chat kept behind
// another section of the home shell does not mark them.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
  late SyncEngine engine;

  Future<void> start(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    final store = LocalStore.open(':memory:')
      ..setMeta(
        'members',
        '[{"id":"m1","username":"mama","displayName":"Mama"},'
            '{"id":"m2","username":"papa","displayName":"Papa"}]',
      );
    engine = SyncEngine(
      store: store,
      api: FamioApiClient('localhost:1'),
      memberId: me.id,
    );
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
  }

  void incoming(String id, String text) => engine.put(
    Collections.chatMessages,
    id,
    ChatMessage(
      id: id,
      chatId: ChatIds.family,
      authorId: 'm2',
      sentAt: DateTime.now(),
      text: text,
    ).toData(),
  );

  testWidgets('wide: the family chat beside the list, then another section', (
    tester,
  ) async {
    await start(tester, const Size(1400, 1000));
    await tester.tap(find.text('Chat').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kalender').first);
    await tester.pumpAndSettle();
    expect(find.text('Hallo?'), findsNothing);
    incoming('w1', 'Hallo?');
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(engine.unreadCount(ChatIds.family), 1);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('phone: chat pushed, then another section', (tester) async {
    await start(tester, const Size(390, 844));
    await tester.tap(find.byTooltip('Chat').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Familie').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Start').first);
    await tester.pumpAndSettle();
    incoming('w2', 'Bist du da?');
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(engine.unreadCount(ChatIds.family), 1);
    // Back in the chat, it is read.
    await tester.tap(find.byTooltip('Chat').first);
    await tester.pumpAndSettle();
    expect(engine.unreadCount(ChatIds.family), 0);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('an open chat marks what arrives', (tester) async {
    await start(tester, const Size(390, 844));
    await tester.tap(find.byTooltip('Chat').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Familie').first);
    await tester.pumpAndSettle();
    incoming('w4', 'Gleich da');
    await tester.pumpAndSettle();
    expect(engine.unreadCount(ChatIds.family), 0);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the chat list alone marks nothing', (tester) async {
    await start(tester, const Size(390, 844));
    await tester.tap(find.byTooltip('Chat').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Start').first);
    await tester.pumpAndSettle();
    incoming('w3', 'Kontrolle');
    await tester.pump();
    await tester.pump();
    expect(engine.unreadCount(ChatIds.family), 1);
    await tester.pump(const Duration(seconds: 1));
  });
}
