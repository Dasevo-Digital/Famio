import '../sync_record.dart';
import '../texts.dart';

enum PantryPlace {
  fridge('Kühlschrank', '🧊'),
  freezer('Tiefkühler', '❄️'),
  pantry('Vorratsschrank', '🥫'),
  other('Sonstiges', '📦');

  const PantryPlace(this._label, this.emoji);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('PantryPlace.$name', _label);
  final String emoji;

  static PantryPlace parse(Object? name) =>
      values.where((p) => p.name == name).firstOrNull ?? pantry;
}

/// Something in stock at home (`Collections.pantryItems`).
class PantryItem {
  const PantryItem({
    required this.id,
    required this.name,
    this.amount = 1,
    this.unit = '',
    this.minAmount = 0,
    this.place = PantryPlace.pantry,
    this.bestBefore,
    this.barcode,
    this.brand = '',
  });

  factory PantryItem.fromRecord(SyncRecord r) => PantryItem(
    id: r.id,
    name: r.data['name'] as String? ?? '',
    amount: (r.data['amount'] as num?)?.toDouble() ?? 0,
    unit: r.data['unit'] as String? ?? '',
    minAmount: (r.data['minAmount'] as num?)?.toDouble() ?? 0,
    place: PantryPlace.parse(r.data['place']),
    bestBefore: _day(r.data['bestBefore']),
    barcode: r.data['barcode'] as String?,
    brand: r.data['brand'] as String? ?? '',
  );

  final String id;
  final String name;
  final double amount;
  final String unit;

  /// Put it on the shopping list at or below this amount; 0 = never.
  final double minAmount;
  final PantryPlace place;
  final DateTime? bestBefore;

  /// EAN/UPC of the product, from the scanner.
  final String? barcode;
  final String brand;

  bool get low => minAmount > 0 && amount <= minAmount;

  /// Days until [bestBefore] (negative when expired), or null.
  int? daysLeft(DateTime today) => bestBefore == null
      ? null
      : DateTime.utc(
          bestBefore!.year,
          bestBefore!.month,
          bestBefore!.day,
        ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;

  String get amountLabel {
    final n = amount == amount.roundToDouble()
        ? amount.toInt().toString()
        : amount.toString().replaceAll('.', ',');
    return unit.isEmpty ? n : '$n $unit';
  }

  PantryItem copyWith({
    String? name,
    double? amount,
    String? unit,
    double? minAmount,
    PantryPlace? place,
    Object? bestBefore = _keep,
    Object? barcode = _keep,
    String? brand,
  }) => PantryItem(
    id: id,
    name: name ?? this.name,
    amount: amount ?? this.amount,
    unit: unit ?? this.unit,
    minAmount: minAmount ?? this.minAmount,
    place: place ?? this.place,
    bestBefore: bestBefore == _keep ? this.bestBefore : bestBefore as DateTime?,
    barcode: barcode == _keep ? this.barcode : barcode as String?,
    brand: brand ?? this.brand,
  );

  Map<String, Object?> toData() => {
    'name': name,
    'amount': amount,
    'unit': unit,
    'minAmount': minAmount,
    'place': place.name,
    'bestBefore': bestBefore == null
        ? null
        : '${bestBefore!.year.toString().padLeft(4, '0')}-'
              '${bestBefore!.month.toString().padLeft(2, '0')}-'
              '${bestBefore!.day.toString().padLeft(2, '0')}',
    'barcode': barcode,
    'brand': brand,
  };
}

const _keep = Object();

DateTime? _day(Object? v) {
  if (v is! String) return null;
  final d = DateTime.tryParse(v);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}
