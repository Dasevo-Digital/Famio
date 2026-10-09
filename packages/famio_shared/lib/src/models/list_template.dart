import '../sync_record.dart';
import '../texts.dart';

/// One entry of a [ListTemplate].
class TemplateItem {
  const TemplateItem(this.name, {this.quantity = '', this.category = ''});

  factory TemplateItem.fromJson(Map<String, Object?> json) => TemplateItem(
    json['name'] as String? ?? '',
    quantity: json['quantity'] as String? ?? '',
    category: json['category'] as String? ?? '',
  );

  final String name;
  final String quantity;
  final String category;

  Map<String, Object?> toJson() => {
    'name': name,
    'quantity': quantity,
    'category': category,
  };
}

/// A reusable list, e.g. the holiday packing list
/// (`Collections.listTemplates`).
class ListTemplate {
  const ListTemplate({
    required this.id,
    required this.name,
    this.emoji = '🧳',
    this.items = const [],
  });

  factory ListTemplate.fromRecord(SyncRecord r) => ListTemplate(
    id: r.id,
    name: r.data['name'] as String? ?? '',
    emoji: r.data['emoji'] as String? ?? '🧳',
    items: [
      for (final i in r.data['items'] as List? ?? [])
        TemplateItem.fromJson((i as Map).cast()),
    ],
  );

  final String id;
  final String name;
  final String emoji;
  final List<TemplateItem> items;

  Map<String, Object?> toData() => {
    'name': name,
    'emoji': emoji,
    'items': [for (final i in items) i.toJson()],
  };
}

/// Ready-made templates offered until the family saves its own.
List<ListTemplate> get builtInTemplates => [
  ListTemplate(
    id: 'builtin-urlaub',
    name: sharedText('ListTemplate|Urlaub', 'Urlaub'),
    emoji: '🏖️',
    items: [
      TemplateItem(
        sharedText(
          'TemplateItem|Ausweise & Reisepässe',
          'Ausweise & Reisepässe',
        ),
        category: 'Dokumente',
      ),
      TemplateItem(
        sharedText(
          'TemplateItem|Krankenversichertenkarten',
          'Krankenversichertenkarten',
        ),
        category: 'Dokumente',
      ),
      TemplateItem(
        sharedText(
          'TemplateItem|Buchungsbestätigungen',
          'Buchungsbestätigungen',
        ),
        category: 'Dokumente',
      ),
      TemplateItem(
        sharedText('TemplateItem|Unterwäsche & Socken', 'Unterwäsche & Socken'),
        category: 'Kleidung',
      ),
      TemplateItem(
        sharedText('TemplateItem|Schlafanzüge', 'Schlafanzüge'),
        category: 'Kleidung',
      ),
      TemplateItem(
        sharedText('TemplateItem|Regenjacken', 'Regenjacken'),
        category: 'Kleidung',
      ),
      TemplateItem(
        sharedText('TemplateItem|Badesachen', 'Badesachen'),
        category: 'Kleidung',
      ),
      TemplateItem(
        sharedText(
          'TemplateItem|Zahnbürsten & Zahnpasta',
          'Zahnbürsten & Zahnpasta',
        ),
        category: 'Bad',
      ),
      TemplateItem(
        sharedText('TemplateItem|Sonnencreme', 'Sonnencreme'),
        category: 'Bad',
      ),
      TemplateItem(
        sharedText('TemplateItem|Reiseapotheke', 'Reiseapotheke'),
        category: 'Bad',
      ),
      TemplateItem(
        sharedText('TemplateItem|Ladegeräte', 'Ladegeräte'),
        category: 'Technik',
      ),
      TemplateItem(
        sharedText('TemplateItem|Kuscheltier', 'Kuscheltier'),
        category: 'Kinder',
      ),
      TemplateItem(
        sharedText(
          'TemplateItem|Spiele & Bücher für die Fahrt',
          'Spiele & Bücher für die Fahrt',
        ),
        category: 'Kinder',
      ),
      TemplateItem(
        sharedText('TemplateItem|Snacks & Getränke', 'Snacks & Getränke'),
        category: 'Unterwegs',
      ),
    ],
  ),
  ListTemplate(
    id: 'builtin-kita',
    name: sharedText('ListTemplate|Kita-Tasche', 'Kita-Tasche'),
    emoji: '🎒',
    items: [
      TemplateItem(
        sharedText('TemplateItem|Wechselkleidung', 'Wechselkleidung'),
      ),
      TemplateItem(
        sharedText(
          'TemplateItem|Windeln & Feuchttücher',
          'Windeln & Feuchttücher',
        ),
      ),
      TemplateItem(
        sharedText(
          'TemplateItem|Matschhose & Gummistiefel',
          'Matschhose & Gummistiefel',
        ),
      ),
      TemplateItem(sharedText('TemplateItem|Hausschuhe', 'Hausschuhe')),
      TemplateItem(sharedText('TemplateItem|Trinkflasche', 'Trinkflasche')),
      TemplateItem(sharedText('TemplateItem|Brotdose', 'Brotdose')),
      TemplateItem(
        sharedText('TemplateItem|Sonnenhut / Mütze', 'Sonnenhut / Mütze'),
      ),
    ],
  ),
  ListTemplate(
    id: 'builtin-klinik',
    name: sharedText('ListTemplate|Kliniktasche Geburt', 'Kliniktasche Geburt'),
    emoji: '👶',
    items: [
      TemplateItem(
        sharedText('TemplateItem|Mutterpass', 'Mutterpass'),
        category: 'Dokumente',
      ),
      TemplateItem(
        sharedText(
          'TemplateItem|Versichertenkarte & Ausweis',
          'Versichertenkarte & Ausweis',
        ),
        category: 'Dokumente',
      ),
      TemplateItem(
        sharedText(
          'TemplateItem|Familienstammbuch / Geburtsurkunden',
          'Familienstammbuch / Geburtsurkunden',
        ),
        category: 'Dokumente',
      ),
      TemplateItem(
        sharedText(
          'TemplateItem|Bequeme Kleidung & Bademantel',
          'Bequeme Kleidung & Bademantel',
        ),
        category: 'Mama',
      ),
      TemplateItem(
        sharedText(
          'TemplateItem|Still-BHs & Stilleinlagen',
          'Still-BHs & Stilleinlagen',
        ),
        category: 'Mama',
      ),
      TemplateItem(
        sharedText(
          'TemplateItem|Hausschuhe & warme Socken',
          'Hausschuhe & warme Socken',
        ),
        category: 'Mama',
      ),
      TemplateItem(
        sharedText('TemplateItem|Kulturbeutel', 'Kulturbeutel'),
        category: 'Mama',
      ),
      TemplateItem(
        sharedText('TemplateItem|Ladekabel', 'Ladekabel'),
        category: 'Mama',
      ),
      TemplateItem(
        sharedText('TemplateItem|Erstausstattung Baby', 'Erstausstattung Baby'),
        category: 'Baby',
      ),
      TemplateItem(
        sharedText('TemplateItem|Mützchen & Söckchen', 'Mützchen & Söckchen'),
        category: 'Baby',
      ),
      TemplateItem(
        sharedText('TemplateItem|Babyschale fürs Auto', 'Babyschale fürs Auto'),
        category: 'Baby',
      ),
    ],
  ),
  ListTemplate(
    id: 'builtin-schwimmbad',
    name: sharedText('ListTemplate|Schwimmbad', 'Schwimmbad'),
    emoji: '🏊',
    items: [
      TemplateItem(sharedText('TemplateItem|Badesachen', 'Badesachen')),
      TemplateItem(sharedText('TemplateItem|Handtücher', 'Handtücher')),
      TemplateItem(sharedText('TemplateItem|Schwimmflügel', 'Schwimmflügel')),
      TemplateItem(
        sharedText('TemplateItem|Duschgel & Shampoo', 'Duschgel & Shampoo'),
      ),
      TemplateItem(sharedText('TemplateItem|Haarbürste', 'Haarbürste')),
      TemplateItem(
        sharedText('TemplateItem|Münzen für den Spind', 'Münzen für den Spind'),
      ),
      TemplateItem(sharedText('TemplateItem|Snacks', 'Snacks')),
    ],
  ),
  ListTemplate(
    id: 'builtin-camping',
    name: sharedText('ListTemplate|Camping', 'Camping'),
    emoji: '⛺',
    items: [
      TemplateItem(sharedText('TemplateItem|Zelt & Heringe', 'Zelt & Heringe')),
      TemplateItem(
        sharedText(
          'TemplateItem|Schlafsäcke & Isomatten',
          'Schlafsäcke & Isomatten',
        ),
      ),
      TemplateItem(sharedText('TemplateItem|Stirnlampen', 'Stirnlampen')),
      TemplateItem(
        sharedText('TemplateItem|Campingkocher & Gas', 'Campingkocher & Gas'),
      ),
      TemplateItem(
        sharedText('TemplateItem|Geschirr & Besteck', 'Geschirr & Besteck'),
      ),
      TemplateItem(sharedText('TemplateItem|Mückenschutz', 'Mückenschutz')),
      TemplateItem(
        sharedText('TemplateItem|Erste-Hilfe-Set', 'Erste-Hilfe-Set'),
      ),
    ],
  ),
];
