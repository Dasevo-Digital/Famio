// Renders app screens with demo data to PNG files, for design reviews and
// store screenshots:
//
//   FAMIO_SHOTS=/some/dir flutter test tool/render_screens_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> assets) async {
    final loader = FontLoader(family);
    for (final a in assets) {
      loader.addFont(rootBundle.load(a));
    }
    await loader.load();
  }

  await load('Nunito', [
    for (final w in [400, 600, 700, 800]) 'assets/fonts/Nunito-$w.ttf',
  ]);
  await load('Fredoka', [
    'assets/fonts/Fredoka-500.ttf',
    'assets/fonts/Fredoka-600.ttf',
  ]);
  await load('packages/lucide_icons_flutter/Lucide', [
    'packages/lucide_icons_flutter/assets/lucide.ttf',
  ]);
}

String _weatherCache() {
  final now = DateTime.now();
  String hour(int h) => DateTime(
    now.year,
    now.month,
    now.day,
    now.hour + h,
  ).toIso8601String().substring(0, 16);
  return jsonEncode({
    'key': '53.57,10.0',
    'fetched': now.toIso8601String(),
    'data': {
      'current': {
        'time': hour(0),
        'temperature_2m': 9.4,
        'apparent_temperature': 6.8,
        'precipitation': 0.2,
        'weather_code': 61,
        'wind_speed_10m': 18.0,
        'uv_index': 1.0,
      },
      'hourly': {
        'time': [for (var h = 0; h < 12; h++) hour(h)],
        'temperature_2m': [for (var h = 0; h < 12; h++) 9.4 - h * 0.3],
        'apparent_temperature': [for (var h = 0; h < 12; h++) 6.8 - h * 0.3],
        'precipitation_probability': [
          for (var h = 0; h < 12; h++) h < 4 ? 70 : 20,
        ],
        'weather_code': [for (var h = 0; h < 12; h++) h < 4 ? 61 : 3],
        'uv_index': [for (var h = 0; h < 12; h++) 1.0],
      },
    },
  });
}

const _members = [
  FamilyMember(
    id: 'mama',
    username: 'mama',
    displayName: 'Sarah',
    isAdmin: true,
    color: 0xFFDB4A7E,
  ),
  FamilyMember(
    id: 'papa',
    username: 'papa',
    displayName: 'Tom',
    color: 0xFF3587D6,
  ),
  FamilyMember(
    id: 'lena',
    username: 'lena',
    displayName: 'Lena',
    color: 0xFF2A9D6E,
  ),
];

final _membersJson = jsonEncode([for (final m in _members) m.toJson()]);

void _seed(SyncEngine e) {
  final now = DateTime.now();
  final today = DateUtils.dateOnly(now);
  for (final (i, t) in [
    ('Müll rausbringen', 'lena', 0),
    ('Elternbrief unterschreiben', 'mama', 1),
    ('Fahrradreifen flicken', 'papa', 3),
    ('Geburtstagsgeschenk für Oma', null, null),
  ].indexed) {
    e.saveTask(
      Task(
        id: 't$i',
        title: t.$1,
        assigneeId: t.$2,
        due: t.$3 == null ? null : today.add(Duration(days: t.$3!)),
        createdAt: now,
      ),
    );
  }
  e.saveShoppingList(const ShoppingList(id: 'l1', name: 'Wocheneinkauf'));
  e.saveShoppingList(const ShoppingList(id: 'l2', name: 'Drogerie', sort: 1));
  for (final (i, name) in [
    'Milch',
    'Äpfel',
    'Brot',
    'Nudeln',
    'Tomaten',
  ].indexed) {
    e.saveShoppingItem(
      ShoppingItem(
        id: 's$i',
        listId: 'l1',
        name: name,
        quantity: i == 1 ? '6' : '',
        checked: i == 4,
      ),
    );
  }
  e.saveShoppingItem(
    const ShoppingItem(id: 'd1', listId: 'l2', name: 'Zahnpasta'),
  );
  e
    ..saveEvent(
      CalendarEvent(
        id: 'e1',
        title: 'Fußballtraining',
        start: today.add(const Duration(hours: 17, minutes: 30)),
        end: today.add(const Duration(hours: 19)),
        memberIds: const ['lena'],
        location: 'Sportplatz',
        recurrence: const Recurrence(RecurrenceFrequency.weekly),
      ),
    )
    ..saveEvent(
      CalendarEvent(
        id: 'e2',
        title: 'Elternabend',
        start: today.add(const Duration(days: 2, hours: 19)),
        end: today.add(const Duration(days: 2, hours: 21)),
        memberIds: const ['mama', 'papa'],
      ),
    )
    ..saveEvent(
      CalendarEvent(
        id: 'e3',
        title: 'Oma Geburtstag',
        start: today.add(const Duration(days: 5)),
        end: today.add(const Duration(days: 6)),
        allDay: true,
      ),
    );
  final birth = DateTime(today.year - 1, today.month - 2, 12);
  e.saveChild(
    Child(
      id: 'k1',
      name: 'Mia',
      birthDate: birth,
      color: 0xFFE8703A,
      sex: ChildSex.female,
    ),
  );
  e
    ..savePlace(
      const Place(
        id: 'home',
        name: 'Zuhause',
        latitude: 53.5731,
        longitude: 9.9968,
      ),
    )
    ..saveContact(
      FamilyContact(
        id: 'opa',
        name: 'Opa Klaus',
        role: ContactRole.family,
        phone: '040 555',
        birthday: Birthday(
          today.add(const Duration(days: 3)).month,
          today.add(const Duration(days: 3)).day,
          1956,
        ),
      ),
    )
    ..savePregnancy(
      Pregnancy(
        id: 'preg',
        name: 'Krümel',
        dueDate: today.add(const Duration(days: 109)),
        motherId: 'mama',
        guardianIds: const ['mama', 'papa'],
        done: const {'midwife', 'us1', 'us2', 'bag.docs'},
      ),
    );
  e
    ..saveRecipe(
      Recipe(
        id: 'r1',
        title: 'Omas Pfannkuchen',
        servings: 4,
        minutes: 30,
        favorite: true,
        tags: const ['Kinderliebling'],
        ingredients: [
          for (final l in [
            '250 g Mehl',
            '500 ml Milch',
            '3 Eier',
            '1 Prise Salz',
            '2 EL Butter',
          ])
            Ingredient.parse(l),
        ],
        steps:
            'Mehl, Milch, Eier und Salz glatt rühren.\n10 Minuten quellen lassen.\nIn Butter goldbraun ausbacken.',
        source: 'Oma Inge',
      ),
    )
    ..saveRecipe(
      Recipe(
        id: 'r2',
        title: 'Gemüse-Lasagne',
        servings: 4,
        minutes: 75,
        tags: const ['vegetarisch'],
        ingredients: [
          for (final l in [
            '12 Lasagneplatten',
            '2 Zucchini',
            '1 Dose Tomaten',
            '200 g Mozzarella',
          ])
            Ingredient.parse(l),
        ],
      ),
    )
    ..saveRecipe(
      Recipe(
        id: 'r3',
        title: 'Linsen-Bolognese',
        servings: 4,
        minutes: 35,
        ingredients: [
          for (final l in ['200 g rote Linsen', '500 g Spaghetti', '1 Karotte'])
            Ingredient.parse(l),
        ],
      ),
    );
  final monday = today.subtract(Duration(days: today.weekday - 1));
  for (final (i, (d, slot, recipe, title)) in [
    (0, MealSlot.dinner, 'r3', ''),
    (1, MealSlot.dinner, null, 'Reste vom Sonntag'),
    (2, MealSlot.lunch, 'r1', ''),
    (3, MealSlot.dinner, 'r2', ''),
    (4, MealSlot.dinner, null, 'Pizza bestellen 🍕'),
    (today.weekday - 1, MealSlot.breakfast, null, 'Müsli mit Obst'),
  ].indexed) {
    e.saveMeal(
      PlannedMeal(
        id: 'meal$i',
        date: monday.add(Duration(days: d)),
        slot: slot,
        recipeId: recipe,
        title: title,
      ),
    );
  }
  for (final (i, (cents, cat, note, income, monthly)) in [
    (412000, 'Gehalt', 'Gehalt Sarah', true, true),
    (25500, 'Kindergeld', '', true, true),
    (118000, 'Wohnen', 'Miete', false, true),
    (8412, 'Lebensmittel', 'Wocheneinkauf', false, false),
    (6230, 'Lebensmittel', 'Markt', false, false),
    (4500, 'Kinder', 'Schwimmkurs', false, false),
    (3999, 'Freizeit', 'Zoo', false, false),
    (15900, 'Mobilität', 'Tanken', false, false),
  ].indexed) {
    e.saveBudgetEntry(
      BudgetEntry(
        id: 'bud$i',
        date: DateTime(today.year, today.month, 1 + i),
        cents: cents,
        category: cat,
        note: note,
        income: income,
        monthly: monthly,
        memberId: i.isEven ? 'mama' : 'papa',
      ),
    );
  }
  e.saveBudgetSettings(
    const BudgetSettings(
      memberIds: ['mama', 'papa'],
      limits: {'Lebensmittel': 60000, 'Freizeit': 3000, 'Mobilität': 25000},
    ),
  );
  var tt = const Timetable(childId: 'k2', school: 'Grundschule am Park');
  for (final (d, subjects) in [
    (1, ['Deutsch', 'Deutsch', 'Mathe', 'Sachkunde', 'Sport']),
    (2, ['Mathe', 'Englisch', 'Deutsch', 'Kunst']),
    (3, ['Deutsch', 'Mathe', 'Musik', 'Religion', 'Sport', 'Sport']),
    (4, ['Sachkunde', 'Deutsch', 'Mathe', 'Englisch']),
    (5, ['Mathe', 'Deutsch', 'Kunst', 'Kunst']),
  ]) {
    for (final (p, sub) in subjects.indexed) {
      tt = tt.withLesson(d, p, sub, sub == 'Sport' ? 'Halle' : '');
    }
  }
  e.saveTimetable(tt);
  // A baby with a daily log, emergency data and contacts.
  final emilBirth = today.subtract(const Duration(days: 75));
  e
    ..saveContact(
      const FamilyContact(
        id: 'doc',
        name: 'Kinderarztpraxis Dr. Sommer',
        role: ContactRole.pediatrician,
        phone: '040 1234567',
        note: 'Mo–Fr 8–12, Mo/Di/Do 15–18 Uhr',
        childIds: ['k1', 'k3'],
      ),
    )
    ..saveContact(
      const FamilyContact(
        id: 'kita',
        name: 'Kita Sonnenschein',
        role: ContactRole.daycare,
        phone: '040 7654321',
        email: 'info@kita-sonnenschein.example',
        childIds: ['k1'],
      ),
    )
    ..saveContact(
      const FamilyContact(
        id: 'oma',
        name: 'Oma Inge',
        role: ContactRole.family,
        phone: '0171 2345678',
      ),
    )
    ..saveContact(
      const FamilyContact(
        id: 'sitter',
        name: 'Jana (Babysitterin)',
        role: ContactRole.babysitter,
        phone: '0151 9876543',
      ),
    )
    ..saveChild(
      Child(
        id: 'k3',
        name: 'Emil',
        birthDate: emilBirth,
        color: 0xFF3587D6,
        sex: ChildSex.male,
        emergency: const EmergencyInfo(
          allergies: 'keine bekannt',
          conditions: 'Hüftdysplasie (Spreizhose)',
          bloodType: 'A+',
          insurance: 'TK',
          insuranceNumber: 'A123456789',
          doctorContactId: 'doc',
        ),
      ),
    );
  for (final (i, (w, h, head, d)) in [
    (3.4, 51.0, 35.0, 0),
    (3.9, 53.0, 36.5, 10),
    (5.1, 58.0, 39.0, 35),
    (6.0, 61.0, 40.5, 70),
  ].indexed) {
    e.saveChildEntry(
      ChildEntry(
        id: 'em$i',
        childId: 'k3',
        kind: i == 0 ? ChildEntryKind.checkup : ChildEntryKind.measurement,
        refId: i == 0 ? 'U1' : null,
        weightKg: w,
        heightCm: h,
        headCm: head,
        date: emilBirth.add(Duration(days: d)),
      ),
    );
  }
  var n = 0;
  void log(
    LogKind kind,
    Duration ago, {
    Duration? length,
    int? ml,
    BreastSide? side,
    DiaperKind? diaper,
    double? temp,
    String medication = '',
    String dose = '',
    bool running = false,
    String by = 'mama',
  }) {
    final start = now.subtract(ago);
    e.saveChildLog(
      ChildLog(
        id: 'lg${n++}',
        childId: 'k3',
        kind: kind,
        start: start,
        end: running || length == null ? null : start.add(length),
        amountMl: ml,
        side: side,
        diaper: diaper,
        temperatureC: temp,
        medication: medication,
        dose: dose,
        minIntervalHours: medication.isEmpty ? null : 6,
        milk: kind == LogKind.bottle ? MilkKind.breastMilk : null,
        by: by,
      ),
    );
  }

  log(LogKind.sleep, const Duration(minutes: 38), running: true);
  log(
    LogKind.breast,
    const Duration(hours: 1, minutes: 5),
    length: const Duration(minutes: 14),
    side: BreastSide.right,
  );
  log(
    LogKind.diaper,
    const Duration(hours: 1, minutes: 20),
    diaper: DiaperKind.wet,
    by: 'papa',
  );
  log(LogKind.temperature, const Duration(hours: 2), temp: 38.2, by: 'papa');
  log(
    LogKind.medication,
    const Duration(hours: 2),
    medication: 'Fiebersaft',
    dose: 'laut Arzt',
    by: 'papa',
  );
  log(
    LogKind.bottle,
    const Duration(hours: 3, minutes: 40),
    ml: 120,
    by: 'papa',
  );
  log(LogKind.diaper, const Duration(hours: 4), diaper: DiaperKind.both);
  log(
    LogKind.breast,
    const Duration(hours: 6, minutes: 30),
    length: const Duration(minutes: 18),
    side: BreastSide.left,
  );
  for (var d = 1; d < 7; d++) {
    log(
      LogKind.sleep,
      Duration(hours: 24 * d + 3),
      length: Duration(minutes: 540 + d * 17),
    );
    for (var f = 0; f < 5 + d % 3; f++) {
      log(
        LogKind.bottle,
        Duration(hours: 24 * d + f * 3),
        ml: 90 + (f * 30) % 60,
      );
    }
    for (var w = 0; w < 5 + d % 2; w++) {
      log(
        LogKind.diaper,
        Duration(hours: 24 * d + w * 4),
        diaper: w.isEven ? DiaperKind.wet : DiaperKind.both,
      );
    }
  }
  e.saveChild(
    Child(
      id: 'k2',
      name: 'Lena',
      birthDate: DateTime(today.year - 7, 3, 4),
      color: 0xFF2A9D6E,
    ),
  );
  for (final (i, (kind, ref, months, title)) in [
    (ChildEntryKind.milestone, 'smile', 1.5, ''),
    (ChildEntryKind.milestone, 'sit', 6.5, ''),
    (ChildEntryKind.memory, null, 7.0, 'Erster Zahn unten links 🦷'),
    (ChildEntryKind.milestone, 'crawl', 9.0, ''),
    (ChildEntryKind.memory, null, 11.0, 'Erstes Wort: „Mama“'),
    (ChildEntryKind.milestone, 'walk', 13.0, ''),
    (ChildEntryKind.checkup, 'U1', 0.0, ''),
    (ChildEntryKind.checkup, 'U2', 0.1, ''),
    (ChildEntryKind.checkup, 'U3', 1.0, ''),
    (ChildEntryKind.checkup, 'U4', 3.0, ''),
    (ChildEntryKind.checkup, 'U5', 6.0, ''),
    (ChildEntryKind.checkup, 'U6', 11.0, ''),
  ].indexed) {
    e.saveChildEntry(
      ChildEntry(
        id: 'ce$i',
        childId: 'k1',
        kind: kind,
        refId: ref,
        title: title,
        date: birth.add(Duration(days: (months * 30.4).round())),
      ),
    );
  }
  for (final (i, (h, w, m)) in [
    (52.0, 3.6, 0.2),
    (61.0, 6.1, 3.0),
    (68.0, 7.9, 6.0),
    (74.0, 9.2, 11.0),
  ].indexed) {
    e.saveChildEntry(
      ChildEntry(
        id: 'm$i',
        childId: 'k1',
        kind: ChildEntryKind.measurement,
        heightCm: h,
        weightKg: w,
        date: birth.add(Duration(days: (m * 30.4).round())),
      ),
    );
  }
  e
    ..saveDocument(
      FamilyDocument(
        id: 'doc1',
        title: 'Reisepass Sarah',
        category: DocumentCategory.identity,
        file: const FileRef(
          id: 'f1',
          name: 'pass.pdf',
          mime: 'application/pdf',
          size: 820000,
        ),
        memberIds: const ['mama'],
        expiresAt: today.add(const Duration(days: 40)),
        visibleTo: const ['mama', 'papa'],
      ),
    )
    ..saveDocument(
      const FamilyDocument(
        id: 'doc2',
        title: 'Impfpass Mia',
        category: DocumentCategory.health,
        file: FileRef(
          id: 'f2',
          name: 'impfpass.pdf',
          mime: 'application/pdf',
          size: 410000,
        ),
        memberIds: [],
      ),
    )
    ..saveDocument(
      const FamilyDocument(
        id: 'doc3',
        title: 'Hausratversicherung',
        category: DocumentCategory.insurance,
        file: FileRef(
          id: 'f3',
          name: 'police.pdf',
          mime: 'application/pdf',
          size: 1200000,
        ),
      ),
    )
    ..saveDocument(
      const FamilyDocument(
        id: 'doc4',
        title: 'Zeugnis 1. Klasse',
        category: DocumentCategory.school,
        file: FileRef(
          id: 'f4',
          name: 'zeugnis.pdf',
          mime: 'application/pdf',
          size: 300000,
        ),
        memberIds: ['lena'],
      ),
    );
  void chat(
    String id,
    String chat,
    String author,
    String text,
    int minutesAgo, {
    List<String>? to,
  }) {
    e.put(
      Collections.chatMessages,
      id,
      ChatMessage(
        id: id,
        chatId: chat,
        authorId: author,
        text: text,
        sentAt: now.subtract(Duration(minutes: minutesAgo)),
        visibleTo: to,
      ).toData(),
    );
  }

  chat(
    'c1',
    ChatIds.family,
    'papa',
    'Wer holt heute Lena vom Training ab?',
    95,
  );
  chat('c2', ChatIds.family, 'mama', 'Ich mache das 🙋‍♀️', 90);
  chat('c3', ChatIds.family, 'lena', 'Danke Mama!! Kann Emma mitkommen?', 42);
  chat('c4', ChatIds.family, 'papa', 'Klar, ich kaufe noch Pizza 🍕', 12);
  e.markChatRead(ChatIds.family, at: now.subtract(const Duration(minutes: 50)));
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pumpAndSettle();
  final dir = Platform.environment['FAMIO_SHOTS'] ?? 'build/screens';
  Directory(dir).createSync(recursive: true);
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// Answers the admin endpoints with demo data.
http.Client _adminApi() {
  final now = DateTime.now();
  DeviceSession session(String device, Duration ago, {bool current = false}) =>
      DeviceSession(
        id: device.hashCode.toRadixString(16),
        device: device,
        createdAt: now.subtract(const Duration(days: 40)),
        lastSeen: now.subtract(ago),
        current: current,
      );
  final users = [
    for (final m in _members)
      AdminUser(
        member: m,
        createdAt: now.subtract(const Duration(days: 60)),
        homeAssistant: m.id == 'papa',
        sessions: switch (m.id) {
          'mama' => [
            session('macos (Mamas-MacBook)', Duration.zero, current: true),
            session('android (Pixel 8)', const Duration(minutes: 12)),
          ],
          'papa' => [
            session('android (Galaxy S24)', const Duration(hours: 3)),
            session('windows (Arbeits-PC)', const Duration(days: 2)),
          ],
          _ => [session('android (Tablet)', const Duration(days: 1))],
        },
      ),
  ];
  final overview = ServerOverview(
    version: '0.5.0',
    startedAt: now.subtract(const Duration(days: 3, hours: 4)),
    settings: const ServerSettings(publicUrl: 'https://famio.example.org/'),
    defaults: const ServerSettings(timeZone: 'Europe/Berlin', maxUploadMb: 100),
    effective: const ServerSettings(
      publicUrl: 'https://famio.example.org/',
      timeZone: 'Europe/Berlin',
      maxUploadMb: 100,
    ),
    trustProxy: true,
    databaseBytes: 3 * 1024 * 1024 + 400000,
    fileCount: 86,
    fileBytes: 412 * 1024 * 1024,
    recordCounts: {
      'tasks': 42,
      'events': 118,
      'shopping_items': 64,
      'chat_messages': 530,
      'documents': 23,
      'child_entries': 57,
    },
    memberCount: users.length,
    sessionCount: 5,
    connectedClients: 3,
  );
  return MockClient((request) async {
    final body = switch (request.url.path) {
      '/api/admin/users' => {
        'users': [for (final u in users) u.toJson()],
      },
      '/api/admin/overview' => overview.toJson(),
      _ => null,
    };
    return body == null
        ? http.Response('{"error":"offline"}', 503)
        : http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json'},
          );
  });
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de');
    await _loadFonts();
  });

  Future<GlobalKey> start(
    WidgetTester tester,
    Size size, {
    bool signedIn = true,
    Brightness? brightness,
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    if (brightness != null) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
    }
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    // A test file, kept in tool/ so `flutter test` does not render every time.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({
      'weather.enabled': true,
      'weather.cache': _weatherCache(),
    });
    // ignore: invalid_use_of_visible_for_testing_member
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    if (signedIn) {
      final store = LocalStore.open(':memory:')
        ..setMeta('members', _membersJson);
      final engine = SyncEngine(
        store: store,
        api: FamioApiClient('famio.example.org', httpClient: _adminApi()),
        memberId: 'mama',
      );
      _seed(engine);
      state
        ..me = _members.first
        ..engine = engine;
    }
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: FamioApp(state: state),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> go(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await tester.pumpAndSettle();
  }

  const desktop = Size(1280, 800);
  const phone = Size(390, 844);

  testWidgets('desktop', (tester) async {
    final key = await start(tester, desktop);
    await _shot(tester, key, 'desktop_1_start');
    await go(tester, 'Kalender');
    await _shot(tester, key, 'desktop_2_kalender');
    await go(tester, 'Kinder');
    await go(tester, 'Mia');
    await _shot(tester, key, 'desktop_3_kind_zeitstrahl');
    await go(tester, 'Meilensteine');
    await _shot(tester, key, 'desktop_4_kind_meilensteine');
    await go(tester, 'Dokumente');
    await _shot(tester, key, 'desktop_5_dokumente');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('phone', (tester) async {
    final key = await start(tester, phone);
    await _shot(tester, key, 'phone_1_start');
    await go(tester, 'Aufgaben');
    await _shot(tester, key, 'phone_2_aufgaben');
    await tester.tap(find.byTooltip('Chat').first);
    await tester.pumpAndSettle();
    await go(tester, 'Familie');
    await _shot(tester, key, 'phone_3_chat');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('admin', (tester) async {
    final key = await start(tester, desktop);
    await go(tester, 'Einstellungen');
    await _shot(tester, key, 'desktop_6_einstellungen');
    await go(tester, 'Server-Verwaltung');
    await _shot(tester, key, 'desktop_7_verwaltung_benutzer');
    await go(tester, 'Tom');
    await _shot(tester, key, 'desktop_8_verwaltung_mitglied');
    await tester.tap(find.byTooltip('Zurück').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen').last);
    await tester.pumpAndSettle();
    await _shot(tester, key, 'desktop_9_verwaltung_server');
    await go(tester, 'Status');
    await _shot(tester, key, 'desktop_10_verwaltung_status');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('kids health', (tester) async {
    final key = await start(tester, phone);
    await tester.tap(find.byIcon(AppIcons.dotsThreeCircle));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kinder').last);
    await tester.pumpAndSettle();
    await go(tester, 'Emil');
    await _shot(tester, key, 'phone_5_protokoll');
    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pumpAndSettle();
    await _shot(tester, key, 'phone_6_protokoll_woche');
    await tester.tap(find.byTooltip('Notfall'));
    await tester.pumpAndSettle();
    await _shot(tester, key, 'phone_7_notfall');
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();
    await _shot(tester, key, 'phone_8_notfall_daten');
    await tester.tap(find.byTooltip('Zurück').first);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await go(tester, 'Fläschchen');
    await _shot(tester, key, 'phone_9_flaeschchen');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('kids desktop', (tester) async {
    final key = await start(tester, desktop);
    await go(tester, 'Kinder');
    await go(tester, 'Emil');
    await go(tester, 'Wachstum');
    await _shot(tester, key, 'desktop_11_wachstum');
    await go(tester, 'Vorsorge');
    await _shot(tester, key, 'desktop_12_vorsorge');
    await tester.tap(find.byType(RoundCheck).at(1));
    await tester.pumpAndSettle();
    await _shot(tester, key, 'desktop_13_vorsorge_abhaken');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await go(tester, 'Kontakte');
    await _shot(tester, key, 'desktop_14_kontakte');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('family extras', (tester) async {
    final key = await start(tester, desktop);
    await _shot(tester, key, 'desktop_15_start_wetter');
    await go(tester, 'Kinder');
    await _shot(tester, key, 'desktop_16_kinder_schwanger');
    await go(tester, 'Krümel');
    await _shot(tester, key, 'desktop_17_schwangerschaft');
    await go(tester, 'Termine');
    await _shot(tester, key, 'desktop_18_schwangerschaft_termine');
    await go(tester, 'Wehen');
    await _shot(tester, key, 'desktop_19_wehen');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('planning', (tester) async {
    final key = await start(tester, desktop);
    await go(tester, 'Essen');
    await _shot(tester, key, 'desktop_20_essen_woche');
    await go(tester, 'Rezepte');
    await _shot(tester, key, 'desktop_21_rezepte');
    await go(tester, 'Omas Pfannkuchen');
    await _shot(tester, key, 'desktop_22_rezept');
    await go(tester, 'Finanzen');
    await _shot(tester, key, 'desktop_23_finanzen');
    await go(tester, 'Kinder');
    await go(tester, 'Lena');
    await go(tester, 'Stundenplan');
    await _shot(tester, key, 'desktop_24_stundenplan');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('phone dark', (tester) async {
    final key = await start(tester, phone, brightness: Brightness.dark);
    await _shot(tester, key, 'phone_4_start_dunkel');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('login', (tester) async {
    final key = await start(tester, phone, signedIn: false);
    await _shot(tester, key, 'phone_0_login');
  });
}
