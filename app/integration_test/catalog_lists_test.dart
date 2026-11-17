// Catalog ALL-143 … ALL-145 (Bring! and Microsoft To Do: connecting,
// mapping lists, syncing both ways, "Jetzt abgleichen" and "Trennen")
// against a throwaway server and a local stand-in for both services:
//
//   tool/integration_tests.sh macos integration_test/catalog_lists_test.dart
//
// The line below makes tool/integration_tests.sh start
// tool/fake_list_services.py and point the server at it
// (FAMIO_TEST_LIST_SERVICES); no real account is contacted. What the other
// app holds is read from the stand-in, what a person changes there is
// written through its test interface (FAMIO_E2E_FAKE_LISTS).
// e2e-fake: lists
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'catalog_kit.dart';

const fakeUrl = String.fromEnvironment('FAMIO_E2E_FAKE_LISTS');

/// The family's application in Microsoft Entra (any id of this form).
const clientId = '6f1e2c3d-4b5a-4c7d-8e9f-0a1b2c3d4e5f';
const bringEmail = 'e2e@example.com';
const bringAccount = 'Bring! ($bringEmail)';
const msAccount = 'Microsoft To Do';

// --- the stand-in for Bring! and Microsoft To Do -------------------------------

/// A call to the stand-in's test interface (`_test/…`).
Future<Object?> fake(String path, [Map<String, Object?>? body]) async {
  expect(fakeUrl, isNotEmpty, reason: 'needs `// e2e-fake: lists`');
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      body == null ? 'GET' : 'POST',
      Uri.parse('$fakeUrl/_test/$path'),
    );
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    if (response.statusCode >= 300) {
      throw TestFailure('Ersatzdienst $path: ${response.statusCode} $text');
    }
    return text.isEmpty ? null : jsonDecode(text);
  } finally {
    client.close();
  }
}

Future<Map<String, Object?>> fakeState() async =>
    ((await fake('state')) as Map).cast<String, Object?>();

/// The entries of the Bring! list [list] by name.
Future<Map<String, ({String spec, bool done})>> bringItems(String list) async {
  final lists = ((await fakeState())['bring'] as Map)['lists'] as List;
  final items = lists.cast<Map>().singleWhere((l) => l['name'] == list);
  return {
    for (final i in (items['items'] as List).cast<Map>())
      i['name'] as String: (spec: i['spec'] as String, done: i['done'] as bool),
  };
}

/// A task in Microsoft To Do as the stand-in keeps it.
typedef MsTask = ({
  String title,
  String note,
  bool done,
  String? dueDay,
  Map<String, Object?>? due,
  List<(String, bool)> steps,
});

/// The tasks of the To Do list [list].
Future<List<MsTask>> msTasks(String list) async {
  final lists = ((await fakeState())['mstodo'] as Map)['lists'] as List;
  final tasks = lists.cast<Map>().singleWhere((l) => l['name'] == list);
  return [
    for (final t in (tasks['tasks'] as List).cast<Map>())
      (
        title: t['title'] as String,
        note: t['note'] as String,
        done: t['done'] as bool,
        dueDay: t['dueDay'] as String?,
        due: (t['due'] as Map?)?.cast<String, Object?>(),
        steps: [
          for (final s in (t['steps'] as List).cast<Map>())
            (s['text'] as String, s['done'] as bool),
        ],
      ),
  ];
}

MsTask msTask(List<MsTask> tasks, String title) =>
    tasks.singleWhere((t) => t.title == title);

/// How often Famio's server asked the services so far.
Future<int> serviceCalls() async {
  final calls = ((await fakeState())['calls'] as Map).cast<String, int>();
  return calls.values.fold<int>(0, (a, b) => a + b);
}

/// The member types [code] on Microsoft's page [page]; the HTTP status.
Future<int> enterCode(String page, String code) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(page));
    final bytes = utf8.encode('code=${Uri.encodeQueryComponent(code)}');
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close();
  }
}

String ymd(DateTime day) => DateFormat('yyyy-MM-dd').format(day);

// --- Famio's side ---------------------------------------------------------------

FamioApiClient? _admin;

/// Another device of the admin: seeds Famio and starts syncs like the app.
Future<FamioApiClient> adminApi() async => _admin ??= await kitAdminApi();

Future<void> seed(
  FamioApiClient api,
  String collection,
  Map<String, Map<String, Object?>> records,
) async {
  final r = await put(api, collection, records);
  expect(
    r.rejected.where((x) => records.containsKey(x.id)).map((x) => x.id),
    isEmpty,
    reason: 'the server takes $collection ${records.keys}',
  );
}

/// No connections, no tasks or shopping lists in Famio, both apps as new.
Future<void> cleanAll() async {
  final admin = await adminApi();
  final accounts = await admin.listAccounts();
  for (final a in accounts) {
    await admin.disconnectListAccount(a.id);
  }
  // A run the last changes started (5 s after them) ends first.
  if (accounts.isNotEmpty) {
    await Future<void>.delayed(const Duration(seconds: 6));
  }
  for (final c in [
    Collections.tasks,
    Collections.shoppingItems,
    Collections.shoppingLists,
  ]) {
    final ids = (await pull(admin, c)).keys.toList();
    if (ids.isNotEmpty) await remove(admin, c, ids);
  }
  await fake('reset', {});
}

Future<ListAccount> accountNamed(String name) async =>
    (await (await adminApi()).listAccounts()).singleWhere(
      (a) => a.name == name,
    );

// --- the app --------------------------------------------------------------------

/// A window as high as a big screen: lists build what is on it.
void tall(WidgetTester tester, {double width = 800, double height = 1600}) {
  tester.view.physicalSize = Size(width, height) * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> until(
  WidgetTester tester,
  bool Function() ok,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  debugPrint('E2E until $what');
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) {
      throw TestFailure('Timed out: $what\nOn screen: ${onScreen()}');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
  for (var i = 0; i < ms ~/ 200; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Finder inDialog(Finder f) => find.descendant(
  of: find.byWidgetPredicate((w) => w is AlertDialog || w is Dialog),
  matching: f,
);

/// The drop-down labelled [label] on the page to map lists.
Finder dropdown(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((w) => w is DropdownButtonFormField),
);

/// The tile of a connected account and things in it.
Finder accountTile(String name) => find.widgetWithText(ListTile, name);
Finder inTile(String name, Finder f) =>
    find.descendant(of: accountTile(name), matching: f);

/// The text under an account's name.
String tileText(WidgetTester tester, String name) => [
  for (final e in inTile(name, find.byType(Text)).evaluate())
    (e.widget as Text).data ?? '',
].join('\n');

/// „Zuletzt …“ as the page writes the time of the last sync.
String lastTime(DateTime at) =>
    de.listsLastTime(DateFormat.Md('de').add_jm().format(at));

Future<void> openConnectPage(WidgetTester tester, String section) async {
  await openSection(tester, section);
  await tap(tester, find.byTooltip(de.commonConnectOtherApps));
  await waitFor(tester, find.text(de.listsConnectBring));
}

/// ⋮ of an account, then [entry].
Future<void> accountMenu(WidgetTester tester, String name, String entry) async {
  await tap(tester, inTile(name, find.byType(PopupMenuButton<String>)));
  await tap(tester, find.text(entry).last);
}

/// The system clipboard while [body] runs: what the app copies.
Future<T> withClipboard<T>(
  WidgetTester tester,
  Future<T> Function(List<String> copied) body,
) async {
  final copied = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add('${(call.arguments as Map)['text']}');
    }
    return null;
  });
  try {
    return await body(copied);
  } finally {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  }
}

// --- shopping lists ---------------------------------------------------------------

/// The name of an item in its card.
Finder itemName(String name) =>
    find.descendant(of: find.byType(SoftCard), matching: find.text(name));

bool struck(WidgetTester tester, String name) =>
    tester.widget<Text>(itemName(name).first).style?.decoration ==
    TextDecoration.lineThrough;

Future<void> addItem(WidgetTester tester, String name) async {
  await enter(tester, find.byType(TextField).first, name);
  await tap(tester, find.byTooltip(de.commonAdd));
  await waitFor(tester, itemName(name));
}

Future<void> swipeAway(WidgetTester tester, String name) async {
  await snackGone(tester);
  await tester.drag(cardOf(name), const Offset(-600, 0));
  await settle(tester, 800);
  await waitGone(tester, itemName(name));
}

void main() {
  catalogBinding();

  testWidgets(
    'ALL-143 Bring!: connect, map a list, merged on the first sync, both ways',
    (tester) async {
      tall(tester);
      await cleanAll();
      final admin = await adminApi();
      // In Bring!: Milch (no amount), Brot; Salz bought recently.
      await fake('bring/item', {'list': 'Zuhause', 'name': 'Milch'});
      await fake('bring/item', {
        'list': 'Zuhause',
        'name': 'Brot',
        'spec': '1 Laib',
      });
      await fake('bring/item', {
        'list': 'Zuhause',
        'name': 'Salz',
        'done': true,
      });
      // In Famio: Milch with an amount, Eier.
      const listId = 'e2e-l-woche';
      await seed(admin, Collections.shoppingLists, {
        listId: const ShoppingList(
          id: listId,
          name: 'E2E Wocheneinkauf',
        ).toData(),
      });
      await seed(admin, Collections.shoppingItems, {
        'e2e-i-milch': const ShoppingItem(
          id: 'e2e-i-milch',
          listId: listId,
          name: 'Milch',
          quantity: '2 l',
        ).toData(),
        'e2e-i-eier': const ShoppingItem(
          id: 'e2e-i-eier',
          listId: listId,
          name: 'Eier',
          quantity: '10',
        ).toData(),
      });
      final state = await startApp(tester);
      final engine = state.engine!;
      List<ShoppingItem> items() => engine.shoppingItems(listId);
      ShoppingItem item(String name) =>
          items().singleWhere((i) => i.name == name);

      // „Bring! verbinden“: e-mail address, password, „Anmelden“.
      await openConnectPage(tester, 'Einkauf');
      await tap(tester, find.text(de.listsConnectBring));
      await enter(tester, inDialog(field(de.commonEmailAddress)), bringEmail);
      await enter(
        tester,
        inDialog(field(de.listsBringPassword)),
        'e2e-bring-passwort',
      );
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSignIn)));
      // Signed in at Bring!; the page to map lists opens by itself. Only
      // shopping lists: „Aufgaben“ cannot go with Bring!.
      final merged = find.text(de.listsEachFamioListChoose(de.listsMerged));
      await waitFor(tester, merged);
      expect(((await fakeState())['bring'] as Map)['logins'], [bringEmail]);
      await waitFor(tester, dropdown('E2E Wocheneinkauf'));
      expect(dropdown(de.sectionTasks), findsNothing);
      await tap(tester, find.byType(CloseButton));
      await waitFor(tester, accountTile(bringAccount));
      expect(
        inTile(bringAccount, find.textContaining(de.listsNoListAssignedYet)),
        findsOneWidget,
      );
      var account = await accountNamed(bringAccount);
      expect(account.isBring, isTrue);
      // The server refuses tasks for Bring! as well.
      final home = (await admin.remoteLists(
        account.id,
      )).singleWhere((l) => l.name == 'Zuhause');
      await expectLater(
        admin.setListLinks(account.id, [
          ListLink(famioList: ListAccount.tasksList, remoteList: home.id),
        ]),
        throwsA(isA<ApiError>()),
      );

      // ⋮ → „Listen zuordnen …“, the Bring! list for the Famio list.
      await accountMenu(tester, bringAccount, de.listsAssignLists);
      await waitFor(tester, merged);
      expect(dropdown(de.sectionTasks), findsNothing);
      await choose(tester, 'E2E Wocheneinkauf', 'Zuhause');
      await tap(tester, find.text(de.commonSave));
      await waitFor(
        tester,
        inTile(
          bringAccount,
          find.textContaining('E2E Wocheneinkauf ↔ Zuhause'),
        ),
        timeout: const Duration(seconds: 60),
      );
      account = await accountNamed(bringAccount);
      expect(account.lastError, isNull);
      expect(
        tileText(tester, bringAccount),
        contains(lastTime(account.lastSync!)),
      );

      // The first sync: Milch is one entry on both sides (Famio's amount),
      // Eier went to Bring!, Brot came to Famio, the bought Salz stays there.
      var there = await bringItems('Zuhause');
      expect(there.keys, unorderedEquals(['Milch', 'Brot', 'Salz', 'Eier']));
      expect(there['Milch'], (spec: '2 l', done: false));
      expect(there['Eier'], (spec: '10', done: false));
      expect(there['Salz'], (spec: '', done: true));
      await engine.sync();
      await until(
        tester,
        () => items().any((i) => i.name == 'Brot'),
        'Brot from Bring!',
      );
      expect(
        items().map((i) => i.name),
        unorderedEquals(['Milch', 'Eier', 'Brot']),
      );
      expect(item('Milch').quantity, '2 l');
      expect(item('Brot').quantity, '1 Laib');
      await back(tester);
      await tap(tester, find.text('E2E Wocheneinkauf'));
      await waitFor(tester, itemName('Brot'));
      expect(itemName('Milch'), findsOneWidget);
      expect(itemName('Salz'), findsNothing);

      // Famio → Bring!: new, ticked off, deleted.
      await addItem(tester, 'Butter');
      await tap(tester, itemName('Eier'));
      await until(tester, () => item('Eier').checked, 'Eier ticked off');
      await swipeAway(tester, 'Milch');
      await snackGone(tester);
      await engine.sync();
      await admin.syncListAccount(account.id);
      there = await bringItems('Zuhause');
      expect(there['Butter'], (spec: '', done: false));
      expect(there['Eier'], (spec: '10', done: true));
      expect(there.containsKey('Milch'), isFalse);
      expect(there['Brot'], (spec: '1 Laib', done: false));

      // Bring! → Famio: new, ticked off (bought), deleted.
      await fake('bring/item', {
        'list': 'Zuhause',
        'name': 'Käse',
        'spec': '200 g',
      });
      await fake('bring/item', {
        'list': 'Zuhause',
        'name': 'Brot',
        'spec': '1 Laib',
        'done': true,
      });
      await fake('bring/remove', {'list': 'Zuhause', 'name': 'Butter'});
      await admin.syncListAccount(account.id);
      await engine.sync();
      await until(
        tester,
        () => items().any((i) => i.name == 'Käse'),
        'Käse from Bring!',
      );
      expect(item('Käse').quantity, '200 g');
      expect(item('Käse').checked, isFalse);
      expect(item('Brot').checked, isTrue);
      expect(items().where((i) => i.name == 'Butter'), isEmpty);
      await waitFor(tester, itemName('Käse'));
      await waitGone(tester, itemName('Butter'));
      expect(struck(tester, 'Brot'), isTrue);
      expect(struck(tester, 'Eier'), isTrue);
      expect(struck(tester, 'Käse'), isFalse);
      // Nothing went back and forth twice.
      there = await bringItems('Zuhause');
      expect(there.keys, unorderedEquals(['Brot', 'Salz', 'Eier', 'Käse']));
      expect((await accountNamed(bringAccount)).lastError, isNull);
      await finish(tester, state);
    },
  );

  testWidgets(
    'ALL-144 Microsoft To Do: sign in with the code, tasks and a list, due '
    'dates and steps both ways',
    (tester) async {
      tall(tester);
      await cleanAll();
      final admin = await adminApi();
      // In To Do: a task named like one in Famio, one with a due date and
      // steps, a finished one; „Apfelsaft“ on a shopping list.
      await fake('mstodo/task', {
        'list': 'Aufgaben',
        'title': 'E2E Arzt anrufen',
        'note': 'Termin für Mai',
      });
      await fake('mstodo/task', {
        'list': 'Aufgaben',
        'title': 'E2E Koffer packen',
        'due': ymd(inDays(5)),
        'steps': [
          {'text': 'Pass', 'done': true},
          {'text': 'Ladekabel', 'done': false},
        ],
      });
      await fake('mstodo/task', {
        'list': 'Aufgaben',
        'title': 'E2E Längst erledigt',
        'done': true,
      });
      await fake('mstodo/task', {'list': 'Einkauf', 'title': 'Apfelsaft'});
      // In Famio.
      final now = DateTime.now();
      await seed(admin, Collections.tasks, {
        'e2e-t-arzt': Task(
          id: 'e2e-t-arzt',
          title: 'E2E Arzt anrufen',
          notes: 'Nummer im Adressbuch',
          createdAt: now,
        ).toData(),
        'e2e-t-steuer': Task(
          id: 'e2e-t-steuer',
          title: 'E2E Steuererklärung',
          due: inDays(10),
          createdAt: now,
          checklist: const [
            TaskStep(id: 'e2e-s-belege', text: 'Belege sammeln'),
            TaskStep(id: 'e2e-s-formular', text: 'Formular', done: true),
          ],
        ).toData(),
      });
      const listId = 'e2e-l-drogerie';
      await seed(admin, Collections.shoppingLists, {
        listId: const ShoppingList(id: listId, name: 'E2E Drogerie').toData(),
      });
      await seed(admin, Collections.shoppingItems, {
        'e2e-i-zahnpasta': const ShoppingItem(
          id: 'e2e-i-zahnpasta',
          listId: listId,
          name: 'Zahnpasta',
        ).toData(),
      });
      final state = await startApp(tester);
      final engine = state.engine!;
      Iterable<Task> tasks(String title) =>
          engine.tasks.where((t) => t.title == title);
      Task task(String title) => tasks(title).single;

      // „Microsoft To Do verbinden“: the application's id, „Weiter“.
      await openConnectPage(tester, 'Aufgaben');
      await tap(tester, find.text(de.listsConnectMsTodo));
      await enter(
        tester,
        inDialog(field(de.listsApplicationClientId)),
        clientId,
      );
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonNext)));
      await waitFor(tester, inDialog(find.text(de.listsSignMicrosoft)));
      await waitFor(tester, inDialog(find.text(de.listsWaitingConfirmation)));
      final flow =
          (((await fakeState())['mstodo'] as Map)['flows'] as List).single
              as Map;
      expect(flow['clientId'], clientId);
      final code = flow['userCode'] as String;
      expect(inDialog(find.text(code)), findsOneWidget);
      // „Code kopieren“.
      final copied = await withClipboard(tester, (copied) async {
        await tap(tester, inDialog(find.byTooltip(de.listsCopyCode)));
        return copied;
      });
      expect(copied, [code]);
      // Famio keeps asking; nothing entered yet, so it keeps waiting.
      await settle(tester, 5000);
      expect(inDialog(find.text(de.listsWaitingConfirmation)), findsOneWidget);
      expect(await admin.listAccounts(), isEmpty);
      // At Microsoft's page shown in the dialog: a wrong code is refused,
      // the copied one confirms the sign-in.
      final page = tester
          .widget<Text>(inDialog(find.textContaining('/devicelogin')))
          .data!;
      expect(page, startsWith(fakeUrl));
      expect(await enterCode(page, 'BCDF2345'), 400);
      expect(await enterCode(page, copied.single), 200);
      final both = find.text(de.listsEachFamioListChoose(de.listsBothKept));
      await waitFor(tester, both);
      await waitGone(tester, find.text(de.listsSignMicrosoft));
      expect((await accountNamed(msAccount)).isBring, isFalse);

      // „Listen zuordnen …“: „Aufgaben“ and a shopping list.
      await tap(tester, find.byType(CloseButton));
      await waitFor(tester, accountTile(msAccount));
      await accountMenu(tester, msAccount, de.listsAssignLists);
      await waitFor(tester, both);
      await choose(tester, de.sectionTasks, 'Aufgaben');
      await choose(tester, 'E2E Drogerie', 'Einkauf');
      await tap(tester, find.text(de.commonSave));
      await waitFor(
        tester,
        inTile(msAccount, find.textContaining('Aufgaben ↔ Aufgaben')),
        timeout: const Duration(seconds: 60),
      );
      expect(
        inTile(msAccount, find.textContaining('E2E Drogerie ↔ Einkauf')),
        findsOneWidget,
      );
      final account = await accountNamed(msAccount);
      expect(account.lastError, isNull);
      expect(
        tileText(tester, msAccount),
        contains(lastTime(account.lastSync!)),
      );

      // The first sync: tasks of the same name both stay (two in each app),
      // due dates and steps go over, the finished one stays in To Do.
      var todo = await msTasks('Aufgaben');
      expect(
        todo.map((t) => t.title),
        unorderedEquals([
          'E2E Arzt anrufen',
          'E2E Arzt anrufen',
          'E2E Koffer packen',
          'E2E Längst erledigt',
          'E2E Steuererklärung',
        ]),
      );
      expect(
        todo.where((t) => t.title == 'E2E Arzt anrufen').map((t) => t.note),
        unorderedEquals(['Termin für Mai', 'Nummer im Adressbuch']),
      );
      final steuer = msTask(todo, 'E2E Steuererklärung');
      expect(steuer.dueDay, ymd(inDays(10)));
      // As Graph keeps it: the moment in UTC.
      expect(steuer.due?['timeZone'], 'UTC');
      expect(steuer.steps, [('Belege sammeln', false), ('Formular', true)]);
      expect(steuer.done, isFalse);
      await engine.sync();
      await until(
        tester,
        () => tasks('E2E Koffer packen').isNotEmpty,
        'Koffer packen from To Do',
      );
      expect(
        tasks('E2E Arzt anrufen').map((t) => t.notes),
        unorderedEquals(['Termin für Mai', 'Nummer im Adressbuch']),
      );
      expect(tasks('E2E Längst erledigt'), isEmpty);
      final koffer = task('E2E Koffer packen');
      expect(koffer.due, inDays(5));
      expect(
        [for (final s in koffer.checklist) (s.text, s.done)],
        [('Pass', true), ('Ladekabel', false)],
      );
      // The shopping list: one item from each side, on both.
      expect(
        engine.shoppingItems(listId).map((i) => i.name),
        unorderedEquals(['Zahnpasta', 'Apfelsaft']),
      );
      expect(
        (await msTasks('Einkauf')).map((t) => t.title),
        unorderedEquals(['Zahnpasta', 'Apfelsaft']),
      );
      await back(tester);
      await waitFor(tester, find.text('E2E Koffer packen'));
      expect(find.text('E2E Arzt anrufen'), findsNWidgets(2));
      expect(find.text('E2E Längst erledigt'), findsNothing);
      expect(
        find.descendant(
          of: cardOf('E2E Koffer packen'),
          matching: find.textContaining('☑ 1/2'),
        ),
        findsOneWidget,
      );

      // Famio → To Do: another due date, a step ticked, one added.
      engine.saveTask(
        koffer.copyWith(
          due: inDays(7),
          checklist: [
            for (final s in koffer.checklist)
              s.text == 'Ladekabel' ? s.copyWith(done: true) : s,
            TaskStep(id: uid('step'), text: 'Sonnenbrille'),
          ],
        ),
        opened: koffer,
      );
      await engine.sync();
      await admin.syncListAccount(account.id);
      todo = await msTasks('Aufgaben');
      final packed = msTask(todo, 'E2E Koffer packen');
      expect(packed.dueDay, ymd(inDays(7)));
      expect(packed.steps, [
        ('Pass', true),
        ('Ladekabel', true),
        ('Sonnenbrille', false),
      ]);

      // To Do → Famio: another due date, a step ticked, one added.
      await fake('mstodo/update', {
        'list': 'Aufgaben',
        'title': 'E2E Steuererklärung',
        'set': {
          'due': ymd(inDays(12)),
          'steps': [
            {'text': 'Belege sammeln', 'done': true},
            {'text': 'Formular', 'done': true},
            {'text': 'Unterschreiben', 'done': false},
          ],
        },
      });
      await admin.syncListAccount(account.id);
      await engine.sync();
      await until(
        tester,
        () => task('E2E Steuererklärung').due == inDays(12),
        'the new due date from To Do',
      );
      expect(
        [
          for (final s in task('E2E Steuererklärung').checklist)
            (s.text, s.done),
        ],
        [
          ('Belege sammeln', true),
          ('Formular', true),
          ('Unterschreiben', false),
        ],
      );
      await waitFor(
        tester,
        find.descendant(
          of: cardOf('E2E Steuererklärung'),
          matching: find.textContaining('☑ 2/3'),
        ),
      );
      // Nothing came back changed: the next sync has nothing to do.
      await admin.syncListAccount(account.id);
      todo = await msTasks('Aufgaben');
      expect(msTask(todo, 'E2E Koffer packen').dueDay, ymd(inDays(7)));
      expect(msTask(todo, 'E2E Steuererklärung').dueDay, ymd(inDays(12)));
      expect(todo, hasLength(5));
      expect((await accountNamed(msAccount)).lastError, isNull);
      await finish(tester, state);
    },
  );

  testWidgets('ALL-145 „Jetzt abgleichen“ and „Trennen“: both apps keep '
      'their entries', (tester) async {
    tall(tester);
    await cleanAll();
    final admin = await adminApi();
    const listId = 'e2e-l-vorrat';
    await seed(admin, Collections.shoppingLists, {
      listId: const ShoppingList(id: listId, name: 'E2E Vorrat').toData(),
    });
    await seed(admin, Collections.shoppingItems, {
      'e2e-i-mehl': const ShoppingItem(
        id: 'e2e-i-mehl',
        listId: listId,
        name: 'Mehl',
      ).toData(),
    });
    await seed(admin, Collections.tasks, {
      'e2e-t-fenster': Task(
        id: 'e2e-t-fenster',
        title: 'E2E Fenster putzen',
        createdAt: DateTime.now(),
      ).toData(),
    });
    await fake('bring/item', {'list': 'Zuhause', 'name': 'Zucker'});
    await fake('mstodo/task', {'list': 'Aufgaben', 'title': 'E2E Rasen mähen'});
    // Both connected and mapped already (ALL-143 and ALL-144 do it in the
    // app).
    final bring = await admin.connectBring(
      email: bringEmail,
      password: 'e2e-bring-passwort',
    );
    final home = (await admin.remoteLists(
      bring.id,
    )).singleWhere((l) => l.name == 'Zuhause');
    await admin.setListLinks(bring.id, [
      ListLink(famioList: listId, remoteList: home.id, remoteName: home.name),
    ]);
    final login = await admin.startMicrosoftLogin(clientId);
    expect(await enterCode(login.verificationUri, login.userCode), 200);
    final ms = await admin.pollMicrosoftLogin(login.flow);
    expect(ms, isNotNull);
    final tasksThere = (await admin.remoteLists(
      ms!.id,
    )).singleWhere((l) => l.name == 'Aufgaben');
    await admin.setListLinks(ms.id, [
      ListLink(
        famioList: ListAccount.tasksList,
        remoteList: tasksThere.id,
        remoteName: tasksThere.name,
      ),
    ]);
    // Both apps have each other's entry now.
    expect(
      (await bringItems('Zuhause')).keys,
      unorderedEquals(['Zucker', 'Mehl']),
    );
    expect(
      (await msTasks('Aufgaben')).map((t) => t.title),
      unorderedEquals(['E2E Rasen mähen', 'E2E Fenster putzen']),
    );

    final state = await startApp(tester);
    final engine = state.engine!;
    List<String> shopping() => [
      for (final i in engine.shoppingItems(listId)) i.name,
    ];
    List<String> taskTitles() => [for (final t in engine.tasks) t.title];
    await openConnectPage(tester, 'Einkauf');
    await waitFor(tester, accountTile(bringAccount));
    await waitFor(tester, accountTile(msAccount));
    expect(
      inTile(bringAccount, find.textContaining('E2E Vorrat ↔ Zuhause')),
      findsOneWidget,
    );
    expect(
      inTile(msAccount, find.textContaining('Aufgaben ↔ Aufgaben')),
      findsOneWidget,
    );

    // New in the other apps meanwhile; the round arrow fetches it now. The
    // stand-in answers slowly, so the turning circle can be seen.
    await fake('bring/item', {'list': 'Zuhause', 'name': 'Hefe'});
    await fake('mstodo/task', {
      'list': 'Aufgaben',
      'title': 'E2E Hecke schneiden',
    });
    await fake('delay', {'seconds': 1.5});
    for (final name in [bringAccount, msAccount]) {
      final before = DateTime.now();
      await tap(tester, inTile(name, find.byTooltip(de.commonSyncNow)));
      await waitFor(
        tester,
        inTile(name, find.byType(CircularProgressIndicator)),
      );
      expect(inTile(name, find.byTooltip(de.commonSyncNow)), findsNothing);
      await waitGone(
        tester,
        inTile(name, find.byType(CircularProgressIndicator)),
        timeout: const Duration(seconds: 60),
      );
      await waitFor(tester, inTile(name, find.byTooltip(de.commonSyncNow)));
      final account = await accountNamed(name);
      expect(account.lastError, isNull, reason: name);
      expect(
        account.lastSync!.isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
        reason: '$name: ${account.lastSync} after $before',
      );
      await until(
        tester,
        () => tileText(tester, name).contains(lastTime(account.lastSync!)),
        '„${lastTime(account.lastSync!)}“ for $name',
      );
    }
    await fake('delay', {'seconds': 0});
    await engine.sync();
    await until(tester, () => shopping().contains('Hefe'), 'Hefe from Bring!');
    await until(
      tester,
      () => taskTitles().contains('E2E Hecke schneiden'),
      'Hecke schneiden from To Do',
    );

    // ⋮ → „Trennen“: the question says what happens.
    for (final name in [bringAccount, msAccount]) {
      await accountMenu(tester, name, de.commonDisconnect);
      await waitFor(tester, inDialog(find.text(de.caldavDisconnectName(name))));
      expect(
        inDialog(find.text(de.listsSyncingEndsEntriesStay)),
        findsOneWidget,
      );
      await tap(tester, inDialog(find.text(de.commonDisconnect)));
      await dialogClosed(tester);
      await waitGone(tester, accountTile(name));
    }
    expect(await admin.listAccounts(), isEmpty);
    expect(find.text(de.listsConnectBring), findsOneWidget);
    expect(find.text(de.listsConnectMsTodo), findsOneWidget);

    // Nothing is missing in either app.
    expect(shopping(), unorderedEquals(['Mehl', 'Zucker', 'Hefe']));
    expect(
      (await bringItems('Zuhause')).keys,
      unorderedEquals(['Zucker', 'Mehl', 'Hefe']),
    );
    expect(
      taskTitles(),
      unorderedEquals([
        'E2E Fenster putzen',
        'E2E Rasen mähen',
        'E2E Hecke schneiden',
      ]),
    );
    expect(
      (await msTasks('Aufgaben')).map((t) => t.title),
      unorderedEquals([
        'E2E Fenster putzen',
        'E2E Rasen mähen',
        'E2E Hecke schneiden',
      ]),
    );

    // The syncing has ended: what changes now stays on its side, and
    // Famio's server asks neither app any more (a change in Famio would
    // start a run after 5 s).
    final calls = await serviceCalls();
    final mehl = engine
        .shoppingItems(listId)
        .singleWhere((i) => i.name == 'Mehl');
    engine.deleteShoppingItem(mehl.id);
    final fenster = engine.tasks.singleWhere(
      (t) => t.title == 'E2E Fenster putzen',
    );
    engine.saveTask(fenster.copyWith(done: true), opened: fenster);
    await engine.sync();
    await fake('bring/item', {'list': 'Zuhause', 'name': 'Eier'});
    await settle(tester, 8000);
    await engine.sync();
    expect(await serviceCalls(), calls);
    expect(
      (await bringItems('Zuhause')).keys,
      unorderedEquals(['Zucker', 'Mehl', 'Hefe', 'Eier']),
    );
    expect(
      msTask(await msTasks('Aufgaben'), 'E2E Fenster putzen').done,
      isFalse,
    );
    expect(shopping(), unorderedEquals(['Zucker', 'Hefe']));
    await back(tester);
    await finish(tester, state);
  });
}
