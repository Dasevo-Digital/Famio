import 'dart:convert';

import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/bank_import.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/theme.dart';
import 'package:famio/src/screens/bank_import_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// CAMT.053 as banks send it (version 08, with a booked payment, a salary
/// in the older layout, a pending booking and a batch of two transfers).
const _camt = '''<?xml version="1.0" encoding="UTF-8"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.08">
<BkToCstmrStmt><Stmt><Id>1</Id>
<Ntry>
  <NtryRef>A1</NtryRef>
  <Amt Ccy="EUR">45.67</Amt><CdtDbtInd>DBIT</CdtDbtInd>
  <Sts><Cd>BOOK</Cd></Sts>
  <BookgDt><Dt>2026-10-08</Dt></BookgDt><ValDt><Dt>2026-10-08</Dt></ValDt>
  <AcctSvcrRef>2026100812345</AcctSvcrRef>
  <NtryDtls><TxDtls>
    <RltdPties><Cdtr><Pty><Nm>REWE Markt GmbH</Nm></Pty></Cdtr></RltdPties>
    <RmtInf><Ustrd>Einkauf 08.10.</Ustrd></RmtInf>
  </TxDtls></NtryDtls>
</Ntry>
<Ntry>
  <Amt Ccy="EUR">2500.00</Amt><CdtDbtInd>CRDT</CdtDbtInd>
  <Sts>BOOK</Sts>
  <BookgDt><DtTm>2026-10-01T08:00:00</DtTm></BookgDt>
  <NtryDtls><TxDtls>
    <RltdPties><Dbtr><Nm>Arbeitgeber AG</Nm></Dbtr></RltdPties>
    <RmtInf><Ustrd>Gehalt Oktober</Ustrd></RmtInf>
  </TxDtls></NtryDtls>
</Ntry>
<Ntry>
  <Amt Ccy="EUR">9.99</Amt><CdtDbtInd>DBIT</CdtDbtInd>
  <Sts><Cd>PDNG</Cd></Sts>
  <BookgDt><Dt>2026-10-09</Dt></BookgDt>
</Ntry>
<Ntry>
  <Amt Ccy="EUR">30.00</Amt><CdtDbtInd>DBIT</CdtDbtInd>
  <Sts><Cd>BOOK</Cd></Sts>
  <BookgDt><Dt>2026-10-05</Dt></BookgDt>
  <AcctSvcrRef>SAMMLER</AcctSvcrRef>
  <NtryDtls>
    <TxDtls><AmtDtls><TxAmt><Amt Ccy="EUR">10.00</Amt></TxAmt></AmtDtls>
      <RltdPties><Cdtr><Nm>Musikschule</Nm></Cdtr></RltdPties></TxDtls>
    <TxDtls><AmtDtls><TxAmt><Amt Ccy="EUR">20.00</Amt></TxAmt></AmtDtls>
      <RltdPties><Cdtr><Nm>Kita Sonnenschein</Nm></Cdtr></RltdPties></TxDtls>
  </NtryDtls>
</Ntry>
</Stmt></BkToCstmrStmt></Document>
''';

/// Sparkasse "CSV-CAMT V2", in Windows-1252 like the original.
final _sparkasse = latin1.encode(
  '"Auftragskonto";"Buchungstag";"Valutadatum";"Buchungstext";'
  '"Verwendungszweck";"Glaeubiger ID";"Mandatsreferenz";'
  '"Kundenreferenz (End-to-End)";"Sammlerreferenz";'
  '"Lastschrift Ursprungsbetrag";"Auslagenersatz Ruecklastschrift";'
  '"Beguenstigter/Zahlungspflichtiger";"Kontonummer/IBAN";'
  '"BIC (SWIFT-Code)";"Betrag";"Waehrung";"Info"\r\n'
  '"DE00";"01.10.26";"01.10.26";"FOLGELASTSCHRIFT";"Miete Oktober";"";"";"";'
  '"";"";"";"Hausverwaltung Müller";"DE11";"BIC";"-850,00";"EUR";'
  '"Umsatz gebucht"\r\n'
  '"DE00";"02.10.26";"02.10.26";"KARTENZAHLUNG";"Apotheke am Markt";"";"";'
  '"";"";"";"";"";"";"";"-12,30";"EUR";"Umsatz vorgemerkt"\r\n',
);

const _dkb = '''"Girokonto";"DE00 1203 0000 0000 0000 00"
""
"Kontostand vom 10.10.2026:";"1.234,56 €"
""
"Buchungsdatum";"Wertstellung";"Status";"Zahlungspflichtige*r";"Zahlungsempfänger*in";"Verwendungszweck";"Umsatztyp";"IBAN";"Betrag (€)";"Gläubiger-ID";"Mandatsreferenz";"Kundenreferenz"
"08.10.26";"08.10.26";"Gebucht";"Max Muster";"dm-drogerie markt";"Einkauf";"Ausgang";"DE22";"-23,45 €";"";"";""
"07.10.26";"07.10.26";"Gebucht";"Familienkasse";"Max Muster";"Kindergeld 10/2026";"Eingang";"DE33";"255,00 €";"";"";""
"09.10.26";"09.10.26";"Vorgemerkt";"Max Muster";"Netflix";"";"Ausgang";"";"-13,99 €";"";"";""
''';

const _ing = '''Umsatzanzeige;Datei erstellt am: 10.10.2026 09:00

IBAN;DE00 5001 0517 0000 0000 00
Zeitraum;01.10.2026 - 10.10.2026
Saldo;1.234,56;EUR

Sortierung;Datum absteigend

In der CSV-Datei finden Sie alle bereits gebuchten Umsätze. Die vorgemerkten Umsätze werden nicht aufgenommen, auch wenn sie in Ihrem Internetbanking angezeigt werden.

Buchung;Wertstellungsdatum;Auftraggeber/Empfänger;Buchungstext;Verwendungszweck;Saldo;Währung;Betrag;Währung
06.10.2026;06.10.2026;ARAL Tankstelle;Lastschrift;Tanken;1.188,89;EUR;-1.061,25;EUR
''';

const _n26 =
    '''"Date","Payee","Account number","Transaction type","Payment reference","Amount (EUR)","Amount (Foreign Currency)","Type Foreign Currency","Exchange Rate"
"2026-10-04","Spotify","","MasterCard Payment","","-10.99","","",""
''';

/// Volksbank: the sign in an unnamed column next to the amount.
const _volksbank =
    '''"Buchungstag";"Valuta";"Auftraggeber/Zahlungsempfänger";"Empfänger/Zahlungspflichtiger";"Konto-Nr.";"IBAN";"BLZ";"BIC";"Vorgang/Verwendungszweck";"Kundenreferenz";"Währung";"Umsatz";" "
"03.10.2026";"03.10.2026";"Max Muster";"HUK-Coburg";"";"DE44";"";"";"Kfz-Versicherung";"";"EUR";"112,40";"S"
''';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  List<(String, int, String, String)> read(Object file) => [
    for (final t in parseBankStatement(
      file is String ? utf8.encode(file) : file as List<int>,
    ))
      (dayKey(t.date), t.cents, t.counterparty, t.purpose),
  ];

  test('CAMT: booked entries, payee by direction, batches split', () {
    expect(read(_camt), [
      ('2026-10-08', -4567, 'REWE Markt GmbH', 'Einkauf 08.10.'),
      ('2026-10-05', -1000, 'Musikschule', ''),
      ('2026-10-05', -2000, 'Kita Sonnenschein', ''),
      ('2026-10-01', 250000, 'Arbeitgeber AG', 'Gehalt Oktober'),
    ]);
    final first = parseBankStatement(utf8.encode(_camt)).first;
    expect(first.importId, 'ref:2026100812345');
  });

  test('CSV of German banks, pending ones left out', () {
    expect(read(_sparkasse), [
      ('2026-10-01', -85000, 'Hausverwaltung Müller', 'Miete Oktober'),
    ]);
    expect(read(_dkb), [
      ('2026-10-08', -2345, 'dm-drogerie markt', 'Einkauf'),
      ('2026-10-07', 25500, 'Familienkasse', 'Kindergeld 10/2026'),
    ]);
    expect(read(_ing), [('2026-10-06', -106125, 'ARAL Tankstelle', 'Tanken')]);
    expect(read(_n26), [
      ('2026-10-04', -1099, 'Spotify', 'MasterCard Payment'),
    ]);
    expect(read(_volksbank), [
      ('2026-10-03', -11240, 'HUK-Coburg', 'Kfz-Versicherung'),
    ]);
  });

  test('other files are refused', () {
    for (final file in ['Hallo;Welt\n1;2\n', '<html><body/></html>', '']) {
      expect(
        () => parseBankStatement(utf8.encode(file)),
        throwsA(isA<BankFormatException>()),
        reason: file,
      );
    }
  });

  test('categories: the family\'s choice first, then words', () {
    BankTransaction t(String who, int cents, [String what = '']) =>
        BankTransaction(
          date: DateTime(2026, 10, 1),
          cents: cents,
          counterparty: who,
          purpose: what,
        );
    final history = [
      BudgetEntry(
        id: '1',
        date: DateTime(2026, 9, 1),
        cents: 3000,
        category: 'Freizeit',
        note: 'REWE Markt GmbH – Grillfest',
      ),
    ];
    expect(suggestBudgetCategory(t('REWE Markt', -500), history), 'Freizeit');
    expect(
      suggestBudgetCategory(t('EDEKA Center', -500), history),
      'Lebensmittel',
    );
    expect(
      suggestBudgetCategory(t('Arbeitgeber AG', 250000, 'Gehalt'), []),
      'Gehalt',
    );
    expect(suggestBudgetCategory(t('Stadtwerke', -6000), []), 'Wohnen');
    expect(suggestBudgetCategory(t('Irgendwer', -100), []), 'Sonstiges');
    expect(
      suggestBudgetCategory(t('Irgendwer', 100), []),
      'Sonstige Einnahmen',
    );
  });

  test('duplicates: imported before, or likely entered by hand', () {
    final t = BankTransaction(
      date: DateTime(2026, 10, 8),
      cents: -4567,
      counterparty: 'REWE',
    );
    expect(bankDuplicate(t, []), isNull);
    expect(
      bankDuplicate(t, [
        BudgetEntry(
          id: 'x',
          date: DateTime(2026, 10, 1),
          cents: 4567,
          category: 'Lebensmittel',
          importId: t.importId,
        ),
      ]),
      BankDuplicate.imported,
    );
    expect(
      bankDuplicate(t, [
        BudgetEntry(
          id: 'x',
          date: DateTime(2026, 10, 10),
          cents: 4567,
          category: 'Lebensmittel',
        ),
      ]),
      BankDuplicate.likely,
    );
    // The rent entered once as monthly.
    final rent = BankTransaction(date: DateTime(2026, 10, 1), cents: -85000);
    expect(
      bankDuplicate(rent, [
        BudgetEntry(
          id: 'm',
          date: DateTime(2026, 1, 3),
          cents: 85000,
          category: 'Wohnen',
          monthly: true,
        ),
      ]),
      BankDuplicate.likely,
    );
    expect(
      bankDuplicate(t, [
        BudgetEntry(
          id: 'x',
          date: DateTime(2026, 10, 20),
          cents: 4567,
          category: 'Lebensmittel',
        ),
      ]),
      isNull,
    );
  });

  testWidgets('new bookings are ticked, known ones not, then added', (
    tester,
  ) async {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    final transactions = parseBankStatement(utf8.encode(_camt));
    engine.saveBudgetEntry(
      BudgetEntry(
        id: 'old',
        date: DateTime(2026, 10, 1),
        cents: 250000,
        category: 'Gehalt',
        income: true,
        note: 'Gehalt',
      ),
    );
    final state = AppState()..engine = engine;
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: famioTheme(Brightness.light),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => BankImportScreen(transactions: transactions),
                ),
              ),
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('4 Buchungen · 1 schon im Haushaltsbuch'), findsOneWidget);
    expect(find.text('Vielleicht schon eingetragen'), findsOneWidget);
    expect(find.text('Lebensmittel'), findsOneWidget);
    expect(find.text('Kinder'), findsNWidgets(2));
    await tester.tap(find.text('3 Buchungen übernehmen'));
    await tester.pumpAndSettle();
    final added = [
      for (final e in engine.budgetEntries)
        if (e.id != 'old') (e.note, e.cents, e.category, e.importId != null),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    expect(added, [
      ('Kita Sonnenschein', 2000, 'Kinder', true),
      ('Musikschule', 1000, 'Kinder', true),
      ('REWE Markt GmbH – Einkauf 08.10.', 4567, 'Lebensmittel', true),
    ]);
  });
}
