// Catalog entries for iPhones (since 7229c71, #567 and #385): what the share
// extension hands over reaches "Teilen an Famio" one share after the other,
// texts go to the inbox, the shopping list, the pin board or the recipe
// import, and famio:// links open their target. In an iOS simulator against
// a throwaway server:
//
//   tool/ios_review_tests.py <simulator id> \
//     --file integration_test/catalog_ios_test.dart
//
// The script writes what the share extension would leave in the app group
// (`share-sheet`); the extension's own sheet ("Famio öffnet …") runs only in
// the system's share menu and is not part of this test. Each test names the
// catalog entries it checks.
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/l10n.dart' show deviceLanguage;
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'catalog_kit.dart';
import 'review_open_test.dart' show b64, hostOk, openLink;

/// What the share extension leaves in the app group for one share (with
/// [pictures]: small PNGs of these names, as from Photos).
Future<void> shareSheet(
  String text, {
  String subject = '',
  List<String> pictures = const [],
}) => hostOk(
  'share-sheet ${b64(jsonEncode({'text': text, 'subject': subject, 'pictures': pictures}))}',
);

Future<void> sheetOpen(WidgetTester tester) => waitFor(
  tester,
  find.text(de.shareTitle),
  timeout: const Duration(seconds: 30),
);

Future<void> dismissSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(20, 20));
  await tester.pump(const Duration(seconds: 1));
  await waitGone(tester, find.text(de.shareTitle));
}

/// The preview line of the sheet shows [text].
Finder preview(String text) => find.descendant(
  of: find.byType(BottomSheet),
  matching: find.textContaining(text),
);

Future<void> saveEditor(WidgetTester tester) async {
  await waitFor(tester, find.text(de.commonSave));
  await tester.pump(const Duration(milliseconds: 500));
  // The keyboard may cover it: closed first, then scrolled to.
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 600));
  var button = find.descendant(
    of: find.byType(BottomSheet),
    matching: find.text(de.commonSave),
  );
  if (button.evaluate().isEmpty) button = find.text(de.commonSave);
  for (var i = 0; i < 10 && button.hitTestable().evaluate().isEmpty; i++) {
    await tester.drag(
      find.byType(Scrollable).hitTestable().first,
      const Offset(0, -300),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }
  await tester.ensureVisible(button.last);
  await tester.pump(const Duration(milliseconds: 300));
  await tap(tester, button.last);
  await tester.pump(const Duration(seconds: 1));
}

Future<void> until(
  WidgetTester tester,
  bool Function() ok,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) {
      throw TestFailure('Timed out: $what\nOn screen: ${onScreen()}');
    }
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// A field showing exactly [text].
Finder fieldWith(String text) => find.byWidgetPredicate(
  (w) => w is EditableText && w.controller.text == text,
);

void main() {
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('GRU-183 two shares before Famio opens: one sheet after the '
      'other, a text into the inbox, a recipe link first', (tester) async {
    final state = await startApp(tester);
    final engine = state.engine!;
    try {
      // Shared twice from other apps, then Famio opens (the extension's
      // link).
      await shareSheet('E2E Aus Notizen\nZweite Zeile vom iPhone');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await shareSheet(
        'https://www.chefkoch.de/rezepte/55/Linsensuppe.html',
        subject: 'E2E Linsensuppe',
      );
      await openLink('famio://share');
      await sheetOpen(tester);
      expect(preview('E2E Aus Notizen'), findsOneWidget);
      expect(preview('E2E Linsensuppe'), findsNothing, reason: 'one at a time');
      await tap(tester, find.text(de.shareToInbox));
      await waitFor(tester, find.text(de.inboxSaved));
      final inbox = [
        for (final r in engine.records(Collections.inbox))
          InboxItem.fromRecord(r),
      ];
      expect(
        inbox.where(
          (i) =>
              i.title == 'E2E Aus Notizen' &&
              i.text == 'Zweite Zeile vom iPhone',
        ),
        hasLength(1),
      );
      // The second share follows by itself, a sheet of its own.
      await until(
        tester,
        () => preview('E2E Linsensuppe').evaluate().isNotEmpty,
        'the second share',
      );
      final recipe = tester.getTopLeft(find.text(de.shareAsRecipe)).dy;
      final toInbox = tester.getTopLeft(find.text(de.shareToInbox)).dy;
      expect(recipe, lessThan(toInbox), reason: 'a recipe site first');
      await dismissSheet(tester);
    } finally {
      await finish(tester, state);
    }
  });

  testWidgets('ALL-132 ALL-157 HAU-023 on the iPhone: a list onto the '
      'shopping list, a text as a note, a recipe link imported', (
    tester,
  ) async {
    // A recipe page, as Safari had it (the iPhone fetches it itself).
    final page = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    page.listen((request) {
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<html><head><title>E2E Pflaumenkuchen</title>'
        '<script type="application/ld+json">${jsonEncode({
          '@context': 'https://schema.org',
          '@type': 'Recipe',
          'name': 'E2E Pflaumenkuchen',
          'recipeYield': '12',
          'recipeIngredient': ['1 kg Pflaumen', '300 g Mehl'],
          'recipeInstructions': ['Pflaumen entsteinen.', 'Backen.'],
        })}</script></head><body>Kuchen</body></html>',
      );
      request.response.close();
    });
    final state = await startApp(tester);
    final engine = state.engine!;
    try {
      // ALL-132: no list yet, Famio makes "Einkauf".
      await engine.sync();
      for (final c in [Collections.shoppingItems, Collections.shoppingLists]) {
        for (final r in engine.records(c).toList()) {
          engine.delete(c, r.id);
        }
      }
      await engine.sync();
      await shareSheet('- E2E Hafermilch\n2. E2E Dinkelbrot\n[ ] E2E Quark');
      await openLink('famio://share');
      await sheetOpen(tester);
      expect(find.text(de.shareItems(3)), findsOneWidget);
      await tap(tester, find.text(de.shareToShopping));
      await waitFor(
        tester,
        find.text(de.shareAddedToList(3, de.sectionShopping)),
      );
      final list = engine.shoppingLists.single;
      expect(list.name, de.sectionShopping);
      expect(engine.shoppingItems(list.id).map((i) => i.name).toSet(), {
        'E2E Hafermilch',
        'E2E Dinkelbrot',
        'E2E Quark',
      });
      await snackGone(tester);

      // ALL-157: a text as a note, the first line its title.
      await shareSheet('E2E Notiz vom iPhone\nZeile zwei\nZeile drei');
      await openLink('famio://share');
      await sheetOpen(tester);
      await tap(tester, find.text(de.shareAsNote));
      await waitFor(tester, fieldWith('E2E Notiz vom iPhone'));
      expect(fieldWith('Zeile zwei\nZeile drei'), findsOneWidget);
      await saveEditor(tester);
      await until(
        tester,
        () => engine.notes.any(
          (n) =>
              n.title == 'E2E Notiz vom iPhone' &&
              n.text == 'Zeile zwei\nZeile drei',
        ),
        'note saved',
      );
      await snackGone(tester);

      // HAU-023: a link with "rezept" in its path: first, then imported.
      final link = 'http://127.0.0.1:${page.port}/rezept/pflaumenkuchen';
      await shareSheet('Schau mal: $link', subject: 'E2E Rezept');
      await openLink('famio://share');
      await sheetOpen(tester);
      expect(
        tester.getTopLeft(find.text(de.shareAsRecipe)).dy,
        lessThan(tester.getTopLeft(find.text(de.shareToInbox)).dy),
      );
      await tap(tester, find.text(de.shareAsRecipe));
      await waitFor(
        tester,
        fieldWith('E2E Pflaumenkuchen'),
        timeout: const Duration(seconds: 40),
      );
      await saveEditor(tester);
      await until(
        tester,
        () => engine.recipes.any((r) => r.title == 'E2E Pflaumenkuchen'),
        'recipe saved',
      );
    } finally {
      await page.close(force: true);
      await finish(tester, state);
    }
  });

  testWidgets('ALL-173 on the iPhone: a photo into the family chat', (
    tester,
  ) async {
    final state = await startApp(tester);
    final engine = state.engine!;
    try {
      await shareSheet('', pictures: ['e2e-iphone-foto.png']);
      await openLink('famio://share');
      await sheetOpen(tester);
      expect(find.text(de.shareToShopping), findsNothing);
      expect(find.text(de.shareAsNote), findsNothing);
      await tap(tester, find.text(de.shareToChat));
      await waitFor(
        tester,
        find.text(de.shareSent),
        timeout: const Duration(seconds: 40),
      );
      await engine.sync();
      final sent = [
        for (final r in engine.records(Collections.chatMessages))
          ChatMessage.fromRecord(r),
      ].where((m) => m.attachment?.name == 'e2e-iphone-foto.png').toList();
      expect(sent, hasLength(1));
      expect(sent.single.chatId, ChatIds.family);
      expect(sent.single.attachment!.mime, startsWith('image/'));
    } finally {
      await finish(tester, state);
    }
  });

  testWidgets('GRU-181 famio:// links on the iPhone: a task, a date far off, '
      'an unknown kind', (tester) async {
    final f = await theFamily();
    final state = await startApp(tester);
    final id = uid('task');
    try {
      await put(f.admin, Collections.tasks, {
        id: Task(
          id: id,
          title: 'E2E iPhone Link',
          assigneeIds: [state.me!.id],
        ).toData(),
      });
      await until(
        tester,
        () => state.engine!.tasks.any((t) => t.id == id),
        'the task here',
      );
      await openLink('famio://open?target=task:$id');
      await waitFor(
        tester,
        find.widgetWithText(TextField, 'E2E iPhone Link'),
        timeout: const Duration(seconds: 30),
      );
      await tester.tapAt(const Offset(20, 20));
      await tester.pump(const Duration(seconds: 1));
      for (final link in [
        'famio://open?target=day:@+275760-09-13T00:00:00.000Z',
        'famio://open?target=foo:1',
      ]) {
        await openLink(link);
        await tester.pump(const Duration(seconds: 3));
        expect(tester.takeException(), isNull, reason: link);
        expect(find.textContaining('275760'), findsNothing, reason: link);
        expect(state.me, isNotNull);
        await waitFor(tester, signedInMark);
      }
    } finally {
      await remove(f.admin, Collections.tasks, [id]);
      await finish(tester, state);
    }
  });
}
