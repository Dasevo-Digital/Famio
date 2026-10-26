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
}
