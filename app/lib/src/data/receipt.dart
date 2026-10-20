import 'package:famio_client/famio_client.dart';

import 'search.dart';

/// What a receipt photo says: the amount to pay and the shop.
typedef ReceiptReading = ({int? cents, String? store});

/// "23,45", "1.234,56", "8.99" (two decimals, so quantities and dates
/// are left alone).
final _amount = RegExp(
  r'(?<![\d.,])(\d{1,3}(?:[.\s]\d{3})*[.,]\d{2}|\d+[.,]\d{2})(?![\d])',
);

/// Words naming the amount to pay, the clearest first.
const _totalWords = [
  'zu zahlen',
  'zahlbetrag',
  'endbetrag',
  'gesamtbetrag',
  'summe',
  'gesamt',
  'total',
  'betrag',
];

/// Lines that carry an amount but not the one to pay.
final _notTotal = RegExp(
  r'zwischen|netto|mwst|ust|steuer|rabatt|gegeben|bar\b|ruckgeld|wechselgeld|'
  r'pfand|punkte|tax|change|cash',
);

/// Reads the text of a receipt (from the device's text recognition): the
/// total and the shop's name from its first lines. Null where not found.
ReceiptReading readReceipt(String text) {
  final lines = [
    for (final l in text.split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  ];
  return (cents: _total(lines), store: _store(lines));
}

int? _cents(String match) => parseEuro(match.replaceAll(' ', ''));

int? _lastAmount(String line) {
  final all = _amount.allMatches(line).toList();
  return all.isEmpty ? null : _cents(all.last.group(1)!);
}

int? _total(List<String> lines) {
  for (final word in _totalWords) {
    for (var i = 0; i < lines.length; i++) {
      final l = foldForSearch(lines[i]);
      if (!l.contains(word) || l.contains(_notTotal)) continue;
      if (_lastAmount(lines[i]) case final c? when c > 0) return c;
      // The amount in its own column: one of the next lines.
      for (var j = i + 1; j < lines.length && j <= i + 3; j++) {
        final next = lines[j];
        if (foldForSearch(next).contains(_notTotal)) break;
        if (_lastAmount(next) case final c?
            when c > 0 && !next.contains(RegExp(r'[A-Za-zÄÖÜäöü]{4,}'))) {
          return c;
        }
      }
    }
  }
  // No word for it: the largest amount that is not cash or tax.
  int? best;
  for (final line in lines) {
    if (foldForSearch(line).contains(_notTotal)) continue;
    for (final m in _amount.allMatches(line)) {
      final c = _cents(m.group(1)!);
      if (c != null && c < 1000000 && (best == null || c > best)) best = c;
    }
  }
  return best;
}

/// Lines at the top that are an address, a phone number or such.
final _notStore = RegExp(
  r'str\.|strasse|platz|weg\b|\d{5}|tel|fax|www|http|ust|steuer|kasse|'
  r'bon|datum|filiale|markt nr|beleg|uhr',
);

String? _store(List<String> lines) {
  for (final line in lines.take(5)) {
    final l = foldForSearch(line);
    if (l.contains(_notStore)) continue;
    final letters = RegExp(r'[A-Za-zÄÖÜäöüß]').allMatches(line).length;
    if (letters < 3 || letters < line.length / 2 || line.length > 30) {
      continue;
    }
    return line;
  }
  return null;
}
