import 'package:famio/src/screens/share_target.dart';
import 'package:famio/src/platform/opened_files.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Change notifications arrive asynchronously: one pump delivers the event,
/// the next renders the rebuilt widgets.
Future<void> pumpData(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  const me = FamilyMember(
    id: 'm1',
    username: 'mama',
    displayName: 'Mama',
    color: 0xFFDB4A7E,
  );
  const papa = FamilyMember(
    id: 'm2',
    username: 'papa',
    displayName: 'Papa',
    color: 0xFF3587D6,
  );
  late SyncEngine engine;

  Future<void> open(WidgetTester tester, String section) async {
    tester.view.physicalSize = const Size(1400, 1000);
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
            '{"id":"m2","username":"papa","displayName":"Papa"},'
            '{"id":"ha","username":"ha","displayName":"Home Assistant",'
            '"role":"service"}]',
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
    await tester.tap(find.text(section).first);
    await tester.pumpAndSettle();
  }

  testWidgets('chat: sending a direct message restricts its audience', (
    tester,
  ) async {
    await open(tester, 'Chat');
    expect(find.text('Familie'), findsWidgets);
    await tester.tap(find.text('Papa'));
    await tester.pumpAndSettle();
    expect(find.text('Privat – nur ihr zwei'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Holst du die Kinder ab?');
    await tester.tap(find.byTooltip('Senden'));
    await pumpData(tester);

    final message = engine.records(Collections.chatMessages).single;
    expect(message.visibleTo, unorderedEquals([me.id, papa.id]));
    expect(find.text('Holst du die Kinder ab?'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('chat: messages from Home Assistant can be read', (tester) async {
    await open(tester, 'Chat');
    // A service account is no chat partner until it wrote something.
    expect(find.text('Home Assistant'), findsNothing);
    engine.put(
      Collections.chatMessages,
      'w1',
      ChatMessage(
        id: 'w1',
        chatId: ChatIds.direct('ha', me.id),
        authorId: 'ha',
        sentAt: DateTime.now(),
        text: 'Waschmaschine fertig',
        visibleTo: const ['ha', 'm1'],
      ).toData(),
    );
    await pumpData(tester);
    expect(find.text('Home Assistant'), findsOneWidget);
    await tester.tap(find.text('Home Assistant'));
    await tester.pumpAndSettle();
    expect(find.text('Waschmaschine fertig'), findsWidgets);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('home initials open the own profile', (tester) async {
    await open(tester, 'Start');

    await tester.tap(find.byTooltip('Mein Profil'));
    await tester.pumpAndSettle();

    expect(find.text('Mein Profil'), findsOneWidget);
  });

  testWidgets('desktop rail fills the height and adapts its scale', (
    tester,
  ) async {
    await open(tester, 'Start');
    final homeIcon = find.byIcon(AppIcons.house).first;
    final tallIconSize = tester.widget<Icon>(homeIcon).size!;
    expect(find.text('Einstellungen'), findsOneWidget);

    tester.view.physicalSize = const Size(1200, 600);
    await tester.pumpAndSettle();

    final lowIconSize = tester.widget<Icon>(homeIcon).size!;
    expect(lowIconSize, lessThan(tallIconSize));
    expect(find.text('Einstellungen'), findsNothing);
  });

  testWidgets('documents: filter by category and show lock for private ones', (
    tester,
  ) async {
    await open(tester, 'Dokumente');
    engine
      ..saveDocument(
        FamilyDocument(
          id: 'd1',
          title: 'Reisepass Mama',
          category: DocumentCategory.identity,
          file: const FileRef(
            id: 'f1',
            name: 'pass.pdf',
            mime: 'application/pdf',
            size: 120000,
          ),
          expiresAt: DateTime.now().add(const Duration(days: 20)),
          visibleTo: const ['m1'],
        ),
      )
      ..saveDocument(
        const FamilyDocument(
          id: 'd2',
          title: 'Hausratversicherung',
          category: DocumentCategory.insurance,
          file: FileRef(
            id: 'f2',
            name: 'police.pdf',
            mime: 'application/pdf',
            size: 90000,
          ),
        ),
      );
    await pumpData(tester);
    expect(find.text('Reisepass Mama'), findsOneWidget);
    expect(find.text('Hausratversicherung'), findsOneWidget);
    expect(find.byTooltip('Sichtbar für: Mama'), findsOneWidget);

    await tester.tap(find.text('Versicherungen'));
    await tester.pumpAndSettle();
    expect(find.text('Reisepass Mama'), findsNothing);
    expect(find.text('Hausratversicherung'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('kids: the log goes back by day, week and month', (tester) async {
    await open(tester, 'Kinder');
    final now = DateTime.now();
    final birth = DateUtils.dateOnly(now.subtract(const Duration(days: 120)));
    ChildLog diaper(String id, DateTime at, DiaperKind kind) => ChildLog(
      id: id,
      childId: 'k1',
      kind: LogKind.diaper,
      start: at,
      diaper: kind,
    );
    engine
      ..saveChild(Child(id: 'k1', name: 'Lena', birthDate: birth))
      ..saveChildLog(
        diaper('a', now.subtract(const Duration(minutes: 5)), DiaperKind.wet),
      )
      // The same weekday a week ago: always "last week".
      ..saveChildLog(
        diaper(
          'b',
          DateTime(now.year, now.month, now.day - 7, 9),
          DiaperKind.dirty,
        ),
      );
    await pumpData(tester);
    await tester.tap(find.text('Lena'));
    await tester.pumpAndSettle();
    expect(find.text('Windel Pipi'), findsOneWidget);
    expect(find.text('Windel Kacka'), findsNothing);

    await tester.tap(find.text('Woche'));
    await tester.pumpAndSettle();
    expect(find.text('Diese Woche'), findsOneWidget);
    expect(find.textContaining('Durchschnitt pro Tag'), findsOneWidget);
    await tester.tap(find.byTooltip('Früher'));
    await tester.pumpAndSettle();
    expect(find.text('Letzte Woche'), findsOneWidget);
    expect(find.text('Windel Kacka'), findsOneWidget);
    expect(find.text('Windel Pipi'), findsNothing);

    await tester.tap(find.text('Heute'));
    await tester.pumpAndSettle();
    expect(find.text('Diese Woche'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, AppIcons.caretRight),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Monat'));
    await tester.pumpAndSettle();
    expect(find.text(DateFormat.yMMMM('de').format(now)), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('kids: diapers and how the stool looked', (tester) async {
    await open(tester, 'Kinder');
    final birth = DateUtils.dateOnly(
      DateTime.now().subtract(const Duration(days: 60)),
    );
    engine.saveChild(Child(id: 'k1', name: 'Lena', birthDate: birth));
    await pumpData(tester);
    await tester.tap(find.text('Lena'));
    await tester.pumpAndSettle();
    List<ChildLog> logs() => engine.childLogs('k1');

    // Pipi: one tap, no question about stool.
    await tester.tap(find.text('Pipi'));
    await tester.pumpAndSettle();
    expect(find.text('Pipi eingetragen'), findsOneWidget);
    expect(find.text('Wie war der Stuhl?'), findsNothing);
    expect(logs().single.diaper, DiaperKind.wet);
    expect(logs().single.stool, isNull);

    // Kacka without a rating.
    await tester.tap(find.text('Kacka'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fertig'));
    await tester.pumpAndSettle();
    expect(logs(), hasLength(2));
    expect(
      logs().where((l) => l.diaper == DiaperKind.dirty).single.stool,
      isNull,
    );

    // Closing the sheet at the question keeps the diaper.
    await tester.tap(find.text('Kacka'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('Wie war der Stuhl?'), findsNothing);
    expect(logs(), hasLength(3));

    // Rated afterwards in the editor.
    await tester.tap(find.text('Windel Kacka').first);
    await tester.pumpAndSettle();
    expect(find.text('Beschaffenheit'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'breiig'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'grün'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'normal'));
    await tester.pumpAndSettle();
    // Tapped again, a choice goes away.
    await tester.tap(find.widgetWithText(ChoiceChip, 'normal'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Speichern'));
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final rated = logs().firstWhere((l) => l.stool != null);
    expect(rated.stool, StoolKind.soft);
    expect(rated.stoolColor, StoolColor.green);
    expect(rated.stoolAmount, isNull);
    expect(find.text('Windel Kacka · breiig · grün'), findsOneWidget);

    // Pipi has no stool: switching back drops the rating.
    await tester.tap(find.text('Windel Kacka · breiig · grün'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Durchfall'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<DiaperKind>),
        matching: find.text('Pipi'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Beschaffenheit'), findsNothing);
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final changed = logs().firstWhere((l) => l.id == rated.id);
    expect(changed.diaper, DiaperKind.wet);
    expect(changed.stool, isNull);

    // All three answers in the quick sheet close it.
    await tester.tap(find.text('Kacka'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'viel'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'geformt'));
    await tester.pumpAndSettle();
    expect(find.text('Wie war der Stuhl?'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'weißlich/grau'));
    await tester.pumpAndSettle();
    expect(find.text('Wie war der Stuhl?'), findsNothing);
    final full = logs().firstWhere((l) => l.stoolColor == StoolColor.pale);
    expect(full.stool, StoolKind.formed);
    expect(full.stoolAmount, StoolAmount.much);
    expect(
      find.text('Windel Kacka · geformt · weißlich/grau · viel'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('kids: foot length is a measurement', (tester) async {
    await open(tester, 'Kinder');
    final birth = DateUtils.dateOnly(
      DateTime.now().subtract(const Duration(days: 300)),
    );
    engine.saveChild(Child(id: 'k1', name: 'Lena', birthDate: birth));
    await pumpData(tester);
    await tester.tap(find.text('Lena'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Messen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Fuß (cm)'), '11,5');
    await tester.ensureVisible(find.text('Speichern'));
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final entry = engine.childEntries('k1').single;
    expect(entry.kind, ChildEntryKind.measurement);
    expect(entry.footCm, 11.5);
    expect(entry.heightCm, isNull);
    await tester.tap(find.text('Wachstum'));
    await tester.pumpAndSettle();
    expect(find.text('Fuß 11,5 cm'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('kids: drinks and walks in the log', (tester) async {
    await open(tester, 'Kinder');
    final birth = DateUtils.dateOnly(
      DateTime.now().subtract(const Duration(days: 300)),
    );
    engine.saveChild(Child(id: 'k1', name: 'Lena', birthDate: birth));
    await pumpData(tester);
    await tester.tap(find.text('Lena'));
    await tester.pumpAndSettle();
    List<ChildLog> logs() => engine.childLogs('k1');

    // A drink: what and how much.
    await tester.tap(find.text('Getränk'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Tee'));
    await tester.tap(find.widgetWithText(ActionChip, '150'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Speichern'));
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final drink = logs().single;
    expect(drink.kind, LogKind.drink);
    expect(drink.drink, DrinkKind.tea);
    expect(drink.amountMl, 150);
    expect(find.text('Getränk · 150 ml · Tee'), findsOneWidget);
    expect(find.text('Getränke'), findsOneWidget);
    expect(find.text('150 ml'), findsOneWidget);

    // A walk runs like sleep: started with a tap, ended with another.
    await tester.tap(find.text('Spaziergang'));
    await tester.pump();
    await tester.pump();
    final walk = logs().firstWhere((l) => l.kind == LogKind.walk);
    expect(walk.running, isTrue);
    expect(find.textContaining('Unterwegs seit'), findsOneWidget);
    await tester.tap(find.text('Wieder da'));
    await tester.pump();
    await tester.pump();
    expect(logs().firstWhere((l) => l.id == walk.id).running, isFalse);
    expect(find.textContaining('Unterwegs seit'), findsNothing);
    expect(find.text('Spaziergang'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('kids: week and month show what was drunk', (tester) async {
    await open(tester, 'Kinder');
    final birth = DateUtils.dateOnly(
      DateTime.now().subtract(const Duration(days: 300)),
    );
    // Today, so that the entries are in the current week on any weekday.
    final today = DateUtils.dateOnly(DateTime.now());
    ChildLog drink(String id, DrinkKind? kind, int? ml) => ChildLog(
      id: id,
      childId: 'k1',
      kind: LogKind.drink,
      start: today.add(const Duration(minutes: 1)),
      drink: kind,
      amountMl: ml,
    );
    engine
      ..saveChild(Child(id: 'k1', name: 'Lena', birthDate: birth))
      ..saveChildLog(drink('a', DrinkKind.water, 900))
      ..saveChildLog(drink('b', DrinkKind.water, 300))
      ..saveChildLog(drink('c', DrinkKind.tea, 300))
      ..saveChildLog(drink('d', null, null));
    await pumpData(tester);
    await tester.tap(find.text('Lena'));
    await tester.pumpAndSettle();
    expect(find.text('Getränke insgesamt'), findsNothing);

    for (final period in ['Monat', 'Woche']) {
      await tester.tap(find.text(period));
      await tester.pumpAndSettle();
      expect(find.text('Getränke insgesamt'), findsOneWidget);
      expect(find.text('1,5 l'), findsOneWidget);
      expect(find.text('1 von 1'), findsOneWidget);
      expect(find.text('Wasser'), findsOneWidget);
      expect(find.text('1,2 l · 2×'), findsOneWidget);
      expect(find.text('Tee'), findsOneWidget);
      expect(find.text('300 ml · 1×'), findsOneWidget);
      expect(find.text('Anderes'), findsOneWidget);
      expect(find.text('1×'), findsOneWidget);
    }

    // The history can show the amount drunk per day.
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate((w) => w is DropdownButton),
        matching: find.text('Mahlzeiten'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Getränke').last);
    await tester.pumpAndSettle();
    expect(find.text('in ml'), findsOneWidget);
    final bars =
        tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((w) => w.painter)
                .firstWhere((p) => p.runtimeType.toString() == '_BarPainter')
            as dynamic;
    expect((bars.values as List<double>).reduce(math.max), 1500);

    // On a phone with large text the card still fits.
    await tester.tap(find.text('Verstanden'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(390, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('Wasser'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('1,2 l · 2×'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('kids: a log entry shows its photos', (tester) async {
    await open(tester, 'Kinder');
    final birth = DateUtils.dateOnly(
      DateTime.now().subtract(const Duration(days: 60)),
    );
    const photo = FileRef(
      id: 'f1',
      name: 'ausschlag.jpg',
      mime: 'image/jpeg',
      size: 3,
    );
    engine
      ..saveChild(Child(id: 'k1', name: 'Lena', birthDate: birth))
      ..saveChildLog(
        ChildLog(
          id: 'a',
          childId: 'k1',
          kind: LogKind.symptom,
          symptom: 'Ausschlag',
          start: DateTime.now().subtract(const Duration(minutes: 5)),
          photos: const [photo],
        ),
      );
    await pumpData(tester);
    await tester.tap(find.text('Lena'));
    await tester.pumpAndSettle();
    expect(find.byIcon(AppIcons.image), findsOneWidget);
    await tester.tap(find.text('Ausschlag'));
    await tester.pumpAndSettle();
    expect(find.text('Fotos und Dateien'), findsOneWidget);
    // Removed in the editor and saved: the entry has none left.
    await tester.ensureVisible(find.byTooltip('Anhang entfernen').first);
    await tester.tap(find.byTooltip('Anhang entfernen').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Speichern'));
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(engine.childLogs('k1').single.photos, isEmpty);
    expect(find.byIcon(AppIcons.image), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('kids: milestones appear in the timeline', (tester) async {
    await open(tester, 'Kinder');
    final birth = DateTime.now().subtract(const Duration(days: 300));
    engine
      ..saveChild(
        Child(id: 'k1', name: 'Lena', birthDate: DateUtils.dateOnly(birth)),
      )
      ..saveChildEntry(
        ChildEntry(
          id: 'e1',
          childId: 'k1',
          kind: ChildEntryKind.milestone,
          refId: 'sit',
          date: DateUtils.dateOnly(birth.add(const Duration(days: 200))),
        ),
      );
    await pumpData(tester);
    expect(find.text('Lena'), findsOneWidget);
    await tester.tap(find.text('Lena'));
    await tester.pumpAndSettle();

    // Babies open on the daily log: one tap logs a diaper.
    expect(find.text('Protokoll'), findsOneWidget);
    await tester.tap(find.text('Pipi + Kacka'));
    await tester.pumpAndSettle();
    // Saved at once; the sheet then asks about the stool.
    expect(engine.childLogs('k1').single.diaper, DiaperKind.both);
    expect(find.text('Wie war der Stuhl?'), findsOneWidget);
    await tester.tap(find.text('Durchfall'));
    await tester.pumpAndSettle();
    // Saved right away; the other questions are optional.
    expect(engine.childLogs('k1').single.stool, StoolKind.watery);
    await tester.tap(find.text('Fertig'));
    await tester.pumpAndSettle();
    expect(find.text('Wie war der Stuhl?'), findsNothing);
    expect(find.text('Windel Pipi + Kacka · Durchfall'), findsOneWidget);

    await tester.tap(find.text('Zeitstrahl'));
    await tester.pumpAndSettle();
    expect(find.text('Sitzt frei ohne Stütze'), findsOneWidget);
    expect(find.textContaining('Geburt'), findsOneWidget);

    // Check-ups are ticked off right in the list.
    await tester.tap(find.text('Vorsorge'));
    await tester.pumpAndSettle();
    expect(find.textContaining('U6'), findsWidgets);
    await tester.tap(find.byType(RoundCheck).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heute erledigt'));
    await tester.pumpAndSettle();
    expect(
      engine.childEntries('k1').where((e) => e.kind == ChildEntryKind.checkup),
      hasLength(1),
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('kids: older toddlers do not see expired baby milestones', (
    tester,
  ) async {
    await open(tester, 'Kinder');
    final now = DateTime.now();
    engine.saveChild(
      Child(
        id: 't1',
        name: 'Milo',
        birthDate: DateUtils.dateOnly(
          DateTime(now.year - 2, now.month + 1, now.day),
        ),
      ),
    );
    await pumpData(tester);
    await tester.tap(find.text('Milo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Meilensteine'));
    await tester.pumpAndSettle();

    expect(find.text('Hält den Kopf sicher'), findsNothing);
    // Below the development phases of this age.
    await tester.scrollUntilVisible(
      find.text('Rennt'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Rennt'), findsOneWidget);
    expect(find.text('Hält den Kopf sicher'), findsNothing);
  });

  testWidgets('pregnancy: weeks, contractions and the baby arrives', (
    tester,
  ) async {
    await open(tester, 'Kinder');
    // Calendar days: adding 20 × 24 h misses a day across a DST change.
    final now = DateTime.now();
    final due = DateTime(now.year, now.month, now.day + 20);
    engine.savePregnancy(
      Pregnancy(id: 'p1', dueDate: due, name: 'Krümel', guardianIds: [me.id]),
    );
    await pumpData(tester);
    expect(find.text('Krümel'), findsOneWidget);
    expect(find.textContaining('SSW 37+1'), findsOneWidget);
    expect(engine.record(Collections.pregnancies, 'p1')?.visibleTo, [me.id]);
    await tester.tap(find.text('Krümel'));
    await tester.pumpAndSettle();
    // Late in pregnancy it opens on the contraction timer.
    await tester.tap(find.text('Wehe beginnt'));
    await tester.pump();
    await tester.tap(find.text('Wehe vorbei'));
    await tester.pump();
    expect(engine.pregnancy('p1')!.contractions.single.end, isNotNull);

    await tester.tap(find.text('Woche'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Baby ist da!'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Emil');
    await tester.tap(find.text('Junge'));
    await tester.tap(find.text('Kind anlegen'));
    await tester.pumpAndSettle();
    final child = engine.children.single;
    expect(child.name, 'Emil');
    expect(child.sex, ChildSex.male);
    expect(child.guardianIds, [me.id]);
    expect(engine.pregnancy('p1')!.childId, child.id);
    expect(engine.activePregnancies, isEmpty);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('shared text lands on the shopping list, one item per line', (
    tester,
  ) async {
    await open(tester, 'Einkauf');
    engine.saveShoppingList(const ShoppingList(id: 'l1', name: 'Einkauf'));
    await pumpData(tester);
    unawaited(
      showShareTarget(
        tester.element(find.byType(Scaffold).first),
        const SharedContent(text: '- Milch\n- 2 Brot\n\n[ ] Eier'),
        go: (_) {},
        navigatorOf: (_) => null,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Teilen an Famio'), findsOneWidget);
    // Files only go to documents; text has no "Als Dokument".
    expect(find.text('Als Dokument speichern'), findsNothing);
    await tester.tap(find.text('Auf die Einkaufsliste'));
    await tester.pumpAndSettle();
    expect(
      {for (final i in engine.shoppingItems('l1')) i.name: i.quantity},
      {'Milch': '', 'Brot': '2', 'Eier': ''},
    );
    expect(find.text('3 Artikel auf „Einkauf“'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('meals: cooking mode walks through the steps with a timer', (
    tester,
  ) async {
    await open(tester, 'Essen');
    final today = DateUtils.dateOnly(DateTime.now());
    engine
      ..saveRecipe(
        Recipe(
          id: 'r1',
          title: 'Nudeln',
          servings: 2,
          ingredients: [Ingredient.parse('200 g Spaghetti')],
          steps: 'Nudeln 10 Minuten kochen\nAbgießen',
        ),
      )
      ..saveMeal(
        PlannedMeal(
          id: 'm1',
          date: today,
          slot: MealSlot.dinner,
          recipeId: 'r1',
          servings: 4,
        ),
      );
    await pumpData(tester);
    await tester.tap(find.text('Verstanden'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Nudeln'));
    await tester.tap(find.text('Nudeln'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kochmodus'));
    await tester.pumpAndSettle();

    // Ingredients first, for the planned servings; tap ticks one off.
    expect(find.text('400 g Spaghetti'), findsOneWidget);
    await tester.tap(find.text('400 g Spaghetti'));
    await tester.pump();
    await tester.tap(find.text('Weiter'));
    await tester.pumpAndSettle();
    expect(find.text('Nudeln 10 Minuten kochen'), findsOneWidget);
    await tester.tap(find.text('Timer 10 Min.'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Schritt 1 von 2 · 09:5'), findsOneWidget);

    // Leaving asks first while a timer runs.
    await tester.tap(find.byTooltip('Schließen'));
    await tester.pumpAndSettle();
    expect(find.text('Kochmodus verlassen?'), findsOneWidget);
    await tester.tap(find.text('Timer beenden'));
    await tester.pumpAndSettle();
    expect(find.text('Kochmodus'), findsOneWidget);
  });

  testWidgets('meals: plan a recipe and shop its ingredients', (tester) async {
    await open(tester, 'Essen');
    final today = DateUtils.dateOnly(DateTime.now());
    engine
      ..saveShoppingList(const ShoppingList(id: 'l1', name: 'Einkauf'))
      ..saveRecipe(
        Recipe(
          id: 'r1',
          title: 'Pfannkuchen',
          servings: 4,
          ingredients: [
            Ingredient.parse('250 g Mehl'),
            Ingredient.parse('3 Eier'),
          ],
          steps: 'Verrühren\nAusbacken',
        ),
      )
      ..saveMeal(
        PlannedMeal(
          id: 'm1',
          date: today,
          slot: MealSlot.dinner,
          recipeId: 'r1',
          servings: 6,
        ),
      );
    await pumpData(tester);
    expect(find.text('Pfannkuchen'), findsOneWidget);
    await tester.tap(find.text('Zutaten der Woche auf die Einkaufsliste'));
    await tester.pumpAndSettle();
    final items = {
      for (final i in engine.shoppingItems('l1')) i.name: i.quantity,
    };
    expect(items, {'Mehl': '375 g', 'Eier': '4,5'});

    // On a Sunday the meal is the last row, under the snack bar and the
    // tip card: both go first.
    ScaffoldMessenger.of(
      tester.element(find.text('Pfannkuchen')),
    ).hideCurrentSnackBar();
    await tester.tap(find.text('Verstanden'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pfannkuchen'));
    await tester.pumpAndSettle();
    expect(find.text('375 g'), findsOneWidget);
    await tester.tap(find.byTooltip('Weniger'));
    await tester.pumpAndSettle();
    expect(
      find.text('312,5 g').evaluate().isNotEmpty ||
          find.text('313 g').evaluate().isNotEmpty,
      isTrue,
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('budget: month totals and restricted audience', (tester) async {
    await open(tester, 'Finanzen');
    final now = DateTime.now();
    engine
      ..saveBudgetSettings(
        BudgetSettings(
          memberIds: [me.id],
          limits: const {'Lebensmittel': 30000},
        ),
      )
      ..saveBudgetEntry(
        BudgetEntry(
          id: 'b1',
          date: DateTime(now.year, now.month, 1),
          cents: 350000,
          category: 'Gehalt',
          income: true,
          monthly: true,
        ),
      )
      ..saveBudgetEntry(
        BudgetEntry(
          id: 'b2',
          date: DateTime(now.year, now.month, 2),
          cents: 32050,
          category: 'Lebensmittel',
          note: 'Wocheneinkauf',
        ),
      );
    await pumpData(tester);
    expect(find.text('3.500,00 €'), findsOneWidget);
    expect(find.text('3.179,50 €'), findsOneWidget);
    expect(find.text('320,50 € von 300,00 €'), findsOneWidget);
    expect(engine.record(Collections.budgetEntries, 'b2')?.visibleTo, [me.id]);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('timetable: fill in a lesson', (tester) async {
    await open(tester, 'Kinder');
    engine.saveChild(
      Child(id: 'k1', name: 'Lena', birthDate: DateTime(2019, 3, 4)),
    );
    await pumpData(tester);
    await tester.tap(find.text('Lena'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stundenplan'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppIcons.plus).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Mathe');
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(engine.timetable('k1')!.lesson(1, 0)?.subject, 'Mathe');
    // In the grid; on a Sunday the card for tomorrow names it as well.
    expect(
      find.descendant(of: find.byType(Table), matching: find.text('Mathe')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('emergency page shows numbers, allergies and the doctor', (
    tester,
  ) async {
    await open(tester, 'Kinder');
    engine
      ..saveContact(
        const FamilyContact(
          id: 'd1',
          name: 'Dr. Sommer',
          role: ContactRole.pediatrician,
          phone: '040 123456',
        ),
      )
      ..saveChild(
        Child(
          id: 'k1',
          name: 'Lena',
          birthDate: DateTime(2022, 5, 1),
          emergency: const EmergencyInfo(
            allergies: 'Erdnüsse',
            doctorContactId: 'd1',
          ),
        ),
      )
      ..saveChildLog(
        ChildLog(
          id: 'l1',
          childId: 'k1',
          kind: LogKind.medication,
          start: DateTime.now().subtract(const Duration(hours: 2)),
          medication: 'Fiebersaft',
          dose: '5 ml',
        ),
      );
    await pumpData(tester);
    await tester.tap(find.text('Lena'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Notfall'));
    await tester.pumpAndSettle();
    expect(find.text('112 – Notruf'), findsOneWidget);
    expect(find.text('Giftnotruf'), findsOneWidget);
    expect(find.text('Erdnüsse'), findsOneWidget);
    expect(find.text('Dr. Sommer'), findsOneWidget);
    expect(find.textContaining('Fiebersaft · 5 ml'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('contacts are grouped by role', (tester) async {
    await open(tester, 'Kontakte');
    engine
      ..saveContact(
        const FamilyContact(
          id: 'c1',
          name: 'Kita Sonnenschein',
          role: ContactRole.daycare,
        ),
      )
      ..saveContact(
        const FamilyContact(
          id: 'c2',
          name: 'Oma Inge',
          role: ContactRole.family,
          phone: '0171 1',
        ),
      );
    await pumpData(tester);
    expect(find.text('Kita'), findsOneWidget);
    expect(find.text('Familie & Freunde'), findsOneWidget);
    expect(find.text('Oma Inge'), findsOneWidget);
    expect(find.byTooltip('Anrufen: 0171 1'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  test('log reminders: latest feeding and next possible dose', () {
    final child = Child(
      id: 'k1',
      name: 'Lena',
      birthDate: DateTime(2026, 5, 1),
    );
    final t = DateTime(2026, 9, 27, 10);
    final reminders = logReminders(child, [
      ChildLog(
        id: 'b2',
        childId: 'k1',
        kind: LogKind.bottle,
        start: t,
        remindAt: t.add(const Duration(hours: 3)),
      ),
      ChildLog(
        id: 'm1',
        childId: 'k1',
        kind: LogKind.medication,
        start: t.subtract(const Duration(hours: 1)),
        medication: 'Fiebersaft',
        remindAt: t.add(const Duration(hours: 5)),
      ),
      ChildLog(
        id: 'b1',
        childId: 'k1',
        kind: LogKind.bottle,
        start: t.subtract(const Duration(hours: 3)),
        remindAt: t,
      ),
    ]);
    expect(reminders.map((r) => r.key), ['log:b2', 'log:m1']);
    expect(reminders.first.title, 'Nächste Mahlzeit für Lena');
  });

  test('family reminders cover check-ups and expiring documents', () {
    final store = LocalStore.open(':memory:');
    final e = SyncEngine(
      store: store,
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    final now = DateTime(2026, 1, 1, 8);
    e
      ..saveChild(
        Child(
          id: 'k',
          name: 'Ben',
          birthDate: DateTime(2025, 10, 1),
          guardianIds: const ['m1'],
        ),
      )
      ..saveChild(
        Child(
          id: 'x',
          name: 'Fremd',
          birthDate: DateTime(2025, 10, 1),
          guardianIds: const ['m9'],
        ),
      )
      ..saveDocument(
        FamilyDocument(
          id: 'd',
          title: 'Personalausweis',
          category: DocumentCategory.identity,
          file: null,
          expiresAt: DateTime(2026, 1, 20),
        ),
      );
    final titles = [
      for (final r in familyReminders(
        e,
        from: now,
        to: now.add(const Duration(days: 14)),
      ))
        r.title,
    ];
    expect(titles, contains('Personalausweis läuft ab'));
    expect(titles.where((t) => t.contains('Fremd')), isEmpty);
  });
}
