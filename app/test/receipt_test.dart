import 'package:famio/src/data/receipt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a supermarket receipt: the sum, not cash or change', () {
    final r = readReceipt('''
REWE
Musterstraße 12
12345 Musterstadt
EUR
MILCH 3,5%        1,19 B
BROT              2,49 B
KAESE 200G        3,29 B
--------------------------
SUMME EUR         6,97
Geg. BAR EUR     10,00
Rückgeld EUR      3,03
Steuer %   Netto   Steuer   Brutto
B= 7,0%    6,51    0,46     6,97
''');
    expect(r.cents, 697);
    expect(r.store, 'REWE');
  });

  test('the amount in its own column, a line further down', () {
    final r = readReceipt('''
dm-drogerie markt
Filiale 1234
Windeln Gr. 4
Zahnpasta
Zwischensumme
Zu zahlen
14,95
3,45
18,40
''');
    // "Zwischensumme" is skipped; "Zu zahlen" takes the next amount line.
    expect(r.cents, 1495);
    expect(r.store, 'dm-drogerie markt');
  });

  test('other words and formats', () {
    expect(readReceipt('ALDI SÜD\nGesamtbetrag 1.234,56 €').cents, 123456);
    expect(readReceipt('Bäckerei\nTOTAL 8.99').cents, 899);
    expect(readReceipt('Kiosk\nBetrag: 4,50').cents, 450);
  });

  test('no word for it: the largest amount that is not cash', () {
    final r = readReceipt('''
Wochenmarkt
Äpfel 3,20
Kartoffeln 2,80
6,00
Bar 10,00
''');
    expect(r.cents, 600);
  });

  test('nothing to read', () {
    final r = readReceipt('Vielen Dank für Ihren Einkauf');
    expect(r.cents, isNull);
  });
}
