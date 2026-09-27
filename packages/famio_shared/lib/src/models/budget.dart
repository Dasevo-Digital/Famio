import '../sync_record.dart';

/// Default categories of the household budget.
const expenseCategories = [
  'Lebensmittel',
  'Haushalt',
  'Wohnen',
  'Mobilität',
  'Kinder',
  'Gesundheit',
  'Freizeit',
  'Kleidung',
  'Versicherungen',
  'Sonstiges',
];

const incomeCategories = [
  'Gehalt',
  'Kindergeld',
  'Elterngeld',
  'Sonstige Einnahmen',
];

/// Money in or out, stored in `Collections.budgetEntries`.
class BudgetEntry {
  const BudgetEntry({
    required this.id,
    required this.date,
    required this.cents,
    required this.category,
    this.income = false,
    this.note = '',
    this.memberId,
    this.monthly = false,
    this.until,
  });

  factory BudgetEntry.fromRecord(SyncRecord r) => BudgetEntry(
    id: r.id,
    date: _date(r.data['date']) ?? DateTime(2000),
    cents: (r.data['cents'] as num?)?.toInt() ?? 0,
    category: r.data['category'] as String? ?? 'Sonstiges',
    income: r.data['income'] as bool? ?? false,
    note: r.data['note'] as String? ?? '',
    memberId: r.data['memberId'] as String?,
    monthly: r.data['monthly'] as bool? ?? false,
    until: _date(r.data['until']),
  );

  final String id;
  final DateTime date;

  /// Always positive; [income] tells the direction.
  final int cents;
  final String category;
  final bool income;
  final String note;

  /// Who paid or received it.
  final String? memberId;

  /// Repeats every month from [date] on (rent, salary, subscriptions).
  final bool monthly;

  /// Last month of a [monthly] entry (e.g. a cancelled contract).
  final DateTime? until;

  /// Whether the entry counts in [month] (any day of it).
  bool inMonth(DateTime month) {
    final m = month.year * 12 + month.month;
    final from = date.year * 12 + date.month;
    if (!monthly) return m == from;
    final end = until == null ? null : until!.year * 12 + until!.month;
    return m >= from && (end == null || m <= end);
  }

  Map<String, Object?> toData() => {
    'date': _day(date),
    'cents': cents,
    'category': category,
    'income': income,
    'note': note,
    'memberId': memberId,
    'monthly': monthly,
    'until': until == null ? null : _day(until!),
  };
}

/// Budget settings (single record id [BudgetSettings.recordId] in
/// `Collections.budgetSettings`): who may see the budget and monthly limits.
class BudgetSettings {
  const BudgetSettings({this.memberIds = const [], this.limits = const {}});

  static const recordId = 'budget';

  factory BudgetSettings.fromRecord(SyncRecord? r) => r == null
      ? const BudgetSettings()
      : BudgetSettings(
          memberIds: [
            for (final m in r.data['memberIds'] as List? ?? const [])
              m as String,
          ],
          limits: {
            for (final e in (r.data['limits'] as Map? ?? const {}).entries)
              e.key as String: (e.value as num).toInt(),
          },
        );

  /// Members who see the budget; empty means everyone.
  final List<String> memberIds;

  /// Monthly limit per expense category in cents.
  final Map<String, int> limits;

  Map<String, Object?> toData() => {'memberIds': memberIds, 'limits': limits};
}

/// "1.234,56 €".
String formatEuro(int cents) {
  final negative = cents < 0;
  final abs = cents.abs();
  final euros = (abs ~/ 100).toString();
  final grouped = StringBuffer();
  for (var i = 0; i < euros.length; i++) {
    if (i > 0 && (euros.length - i) % 3 == 0) grouped.write('.');
    grouped.write(euros[i]);
  }
  return '${negative ? '−' : ''}$grouped,${(abs % 100).toString().padLeft(2, '0')} €';
}

/// Parses "12,50", "1.234,5" or "12.5" into cents.
int? parseEuro(String text) {
  var t = text.trim().replaceAll('€', '').replaceAll(' ', '');
  if (t.isEmpty) return null;
  if (t.contains(',')) {
    t = t.replaceAll('.', '').replaceAll(',', '.');
  }
  final v = double.tryParse(t);
  return v == null || v < 0 ? null : (v * 100).round();
}

DateTime? _date(Object? v) {
  final d = v is String ? DateTime.tryParse(v) : null;
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
