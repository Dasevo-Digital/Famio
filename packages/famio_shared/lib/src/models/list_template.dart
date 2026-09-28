import '../sync_record.dart';

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
const builtInTemplates = [
  ListTemplate(
    id: 'builtin-urlaub',
    name: 'Urlaub',
    emoji: '🏖️',
    items: [
      TemplateItem('Ausweise & Reisepässe', category: 'Dokumente'),
      TemplateItem('Krankenversichertenkarten', category: 'Dokumente'),
      TemplateItem('Buchungsbestätigungen', category: 'Dokumente'),
      TemplateItem('Unterwäsche & Socken', category: 'Kleidung'),
      TemplateItem('Schlafanzüge', category: 'Kleidung'),
      TemplateItem('Regenjacken', category: 'Kleidung'),
      TemplateItem('Badesachen', category: 'Kleidung'),
      TemplateItem('Zahnbürsten & Zahnpasta', category: 'Bad'),
      TemplateItem('Sonnencreme', category: 'Bad'),
      TemplateItem('Reiseapotheke', category: 'Bad'),
      TemplateItem('Ladegeräte', category: 'Technik'),
      TemplateItem('Kuscheltier', category: 'Kinder'),
      TemplateItem('Spiele & Bücher für die Fahrt', category: 'Kinder'),
      TemplateItem('Snacks & Getränke', category: 'Unterwegs'),
    ],
  ),
  ListTemplate(
    id: 'builtin-kita',
    name: 'Kita-Tasche',
    emoji: '🎒',
    items: [
      TemplateItem('Wechselkleidung'),
      TemplateItem('Windeln & Feuchttücher'),
      TemplateItem('Matschhose & Gummistiefel'),
      TemplateItem('Hausschuhe'),
      TemplateItem('Trinkflasche'),
      TemplateItem('Brotdose'),
      TemplateItem('Sonnenhut / Mütze'),
    ],
  ),
  ListTemplate(
    id: 'builtin-klinik',
    name: 'Kliniktasche Geburt',
    emoji: '👶',
    items: [
      TemplateItem('Mutterpass', category: 'Dokumente'),
      TemplateItem('Versichertenkarte & Ausweis', category: 'Dokumente'),
      TemplateItem(
        'Familienstammbuch / Geburtsurkunden',
        category: 'Dokumente',
      ),
      TemplateItem('Bequeme Kleidung & Bademantel', category: 'Mama'),
      TemplateItem('Still-BHs & Stilleinlagen', category: 'Mama'),
      TemplateItem('Hausschuhe & warme Socken', category: 'Mama'),
      TemplateItem('Kulturbeutel', category: 'Mama'),
      TemplateItem('Ladekabel', category: 'Mama'),
      TemplateItem('Erstausstattung Baby', category: 'Baby'),
      TemplateItem('Mützchen & Söckchen', category: 'Baby'),
      TemplateItem('Babyschale fürs Auto', category: 'Baby'),
    ],
  ),
  ListTemplate(
    id: 'builtin-schwimmbad',
    name: 'Schwimmbad',
    emoji: '🏊',
    items: [
      TemplateItem('Badesachen'),
      TemplateItem('Handtücher'),
      TemplateItem('Schwimmflügel'),
      TemplateItem('Duschgel & Shampoo'),
      TemplateItem('Haarbürste'),
      TemplateItem('Münzen für den Spind'),
      TemplateItem('Snacks'),
    ],
  ),
  ListTemplate(
    id: 'builtin-camping',
    name: 'Camping',
    emoji: '⛺',
    items: [
      TemplateItem('Zelt & Heringe'),
      TemplateItem('Schlafsäcke & Isomatten'),
      TemplateItem('Stirnlampen'),
      TemplateItem('Campingkocher & Gas'),
      TemplateItem('Geschirr & Besteck'),
      TemplateItem('Mückenschutz'),
      TemplateItem('Erste-Hilfe-Set'),
    ],
  ),
];
