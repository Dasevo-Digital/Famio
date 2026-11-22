import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/search.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SyncEngine engine;

  setUp(() {
    engine = SyncEngine(
      store: LocalStore.open(':memory:')
        ..setMeta(
          'members',
          '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true}]',
        ),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    engine
      ..saveTask(const Task(id: 't1', title: 'Müll rausbringen'))
      ..saveTask(
        const Task(id: 't2', title: 'Steuer', notes: 'Belege zum Müll?'),
      )
      ..saveEvent(
        CalendarEvent(
          id: 'e1',
          title: 'Elternabend',
          location: 'Grundschule',
          start: DateTime(2026, 10, 8, 19),
          end: DateTime(2026, 10, 8, 21),
        ),
      )
      ..saveShoppingList(const ShoppingList(id: 'l1', name: 'Einkauf'))
      ..saveShoppingItem(
        const ShoppingItem(
          id: 'i1',
          listId: 'l1',
          name: 'Müllbeutel',
          quantity: '2',
        ),
      )
      ..saveRecipe(
        const Recipe(
          id: 'r1',
          title: 'Pfannkuchen',
          ingredients: [Ingredient(name: 'Eier')],
        ),
      )
      ..saveInboxItem(
        InboxItem(
          id: 'inbox-1',
          title: 'Brief ablegen',
          text: 'Versicherung bis Freitag',
          createdAt: DateTime(2026, 10, 25),
        ),
      );
  });

  final all = FamioSection.values.toSet();

  test('umlauts can be typed either way, all words must match', () {
    expect(foldForSearch('Müll'), foldForSearch('Muell'));
    final hits = searchFamily(engine, 'muell', sections: all);
    expect(hits.map((h) => h.id), containsAll(['t1', 't2', 'i1']));
    expect(
      searchFamily(engine, 'eltern grundschule', sections: all).single.id,
      'e1',
    );
    expect(searchFamily(engine, 'eltern turnhalle', sections: all), isEmpty);
    expect(searchFamily(engine, '   ', sections: all), isEmpty);
  });

  test('titles first, then other fields', () {
    final hits = searchFamily(
      engine,
      'müll',
      sections: all,
    ).where((h) => h.kind == SearchKind.task).toList();
    expect(hits.first.id, 't1');
    expect(hits.last.id, 't2');
  });

  test('ingredients find recipes, shopping hits name their list', () {
    expect(
      searchFamily(engine, 'eier', sections: all).single.kind,
      SearchKind.recipe,
    );
    final bag = searchFamily(engine, 'beutel', sections: all).single;
    expect(bag.detail, 'Einkauf · 2');
  });

  test('switched off areas are not searched', () {
    final hits = searchFamily(
      engine,
      'müll',
      sections: all.difference({FamioSection.shopping}),
    );
    expect(hits.map((h) => h.kind), isNot(contains(SearchKind.shopping)));
  });

  test('family inbox searches text kept for later', () {
    final hit = searchFamily(engine, 'versicherung', sections: all).single;
    expect((hit.kind, hit.id), (SearchKind.inbox, 'inbox-1'));
  });

  test('documents are found by their recognised text', () {
    engine.saveDocument(
      FamilyDocument(
        id: 'd1',
        title: 'Brief Krankenkasse',
        category: DocumentCategory.health,
        file: null,
        content:
            'Sehr geehrte Frau Muster,\n\nanbei Ihre neue Versicherten-'
            'karte. Die Beitragsrückerstattung für 2025 beträgt 120 Euro und '
            'wird im Mai überwiesen. Mit freundlichen Grüßen',
      ),
    );
    final hit = searchFamily(
      engine,
      'beitragsruckerstattung',
      sections: all,
    ).single;
    expect(hit.id, 'd1');
    expect(
      hit.detail,
      'Gesundheit · …Versicherten-karte. Die Beitragsrückerstattung für '
      '2025 bet…',
    );
    // Found by its title: no snippet needed.
    expect(
      searchFamily(engine, 'krankenkasse', sections: all).single.detail,
      'Gesundheit',
    );
    expect(textSnippet('Größe: Straße 5', ['strasse']), 'Größe: Straße 5');
    expect(textSnippet('kurz', ['lang']), isNull);
  });

  test('subscribed calendars and birthdays are found as in the calendar', () {
    engine
      ..saveCalendarSubscription(
        const CalendarSubscription(
          id: 'sub',
          name: 'Schule',
          url: 'https://example.com/s.ics',
        ),
      )
      ..saveContact(
        const FamilyContact(
          id: 'c1',
          name: 'Oma Inge',
          birthday: Birthday(3, 14, 1950),
        ),
      );
    engine.store.put(
      SyncRecord(
        collection: Collections.externalEvents,
        id: 'x1',
        data: CalendarEvent(
          id: 'x1',
          title: 'Sportfest Klasse 3b',
          start: DateTime(2026, 12, 3, 9),
          end: DateTime(2026, 12, 3, 12),
          sourceId: 'sub',
        ).toData(),
        updatedAt: 1,
        rev: 1,
      ),
      dirty: false,
    );
    final sport = searchFamily(engine, 'sportfest', sections: all).single;
    expect(
      (sport.kind, sport.id, sport.detail),
      (SearchKind.event, 'x1', 'Schule'),
    );
    final birthday = searchFamily(
      engine,
      'inge geburtstag',
      sections: all,
    ).single;
    expect(
      (birthday.kind, birthday.id, birthday.title),
      (SearchKind.event, 'birthday:contact:c1', '🎂 Oma Inge'),
    );
    // Switched off with the calendar.
    expect(
      searchFamily(
        engine,
        'sportfest',
        sections: all.difference({FamioSection.calendar}),
      ),
      isEmpty,
    );
  });

  test('only hits cut a snippet, long texts are folded once', () {
    for (var i = 0; i < 3; i++) {
      engine.saveDocument(
        FamilyDocument(
          id: 'd$i',
          title: 'Brief $i',
          category: DocumentCategory.school,
          file: null,
          content:
              'Liebe Eltern, der Wandertag ist bald. ${'Text ' * 200}'
              '${i == 1 ? 'Bitte Regenjacke mitgeben.' : ''}',
        ),
      );
    }
    for (var i = 0; i < 3; i++) {
      engine.put(
        Collections.chatMessages,
        'c$i',
        ChatMessage(
          id: 'c$i',
          chatId: ChatIds.family,
          authorId: 'm1',
          sentAt: DateTime(2026, 10, 1, 9, i),
          text: 'Nachricht $i\nmit zweiter Zeile',
        ).toData(),
      );
    }
    debugSearchTextsFolded = 0;
    debugSearchSnippets = 0;
    final hit = searchFamily(engine, 'regenjacke', sections: all).single;
    expect(hit.id, 'd1');
    expect(hit.detail, contains('Regenjacke'));
    // Three documents and three messages read; one snippet, for the hit.
    expect(debugSearchTextsFolded, 6);
    expect(debugSearchSnippets, 1);
    // The next search folds nothing again.
    debugSearchTextsFolded = 0;
    expect(searchFamily(engine, 'zweiter', sections: all), hasLength(3));
    expect(searchFamily(engine, 'wandertag', sections: all), hasLength(3));
    expect(debugSearchTextsFolded, 0);
    // A changed message is read again, only it.
    engine.put(
      Collections.chatMessages,
      'c0',
      ChatMessage(
        id: 'c0',
        chatId: ChatIds.family,
        authorId: 'm1',
        sentAt: DateTime(2026, 10, 1, 9),
        text: 'Geändert',
      ).toData(),
    );
    expect(searchFamily(engine, 'geandert', sections: all).single.id, 'c0');
    expect(debugSearchTextsFolded, 1);
  });
}
