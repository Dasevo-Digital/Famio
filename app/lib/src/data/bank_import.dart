import 'dart:convert';

import 'package:famio_client/famio_client.dart';
import 'package:xml/xml.dart';

/// One booking of a bank statement.
class BankTransaction {
  const BankTransaction({
    required this.date,
    required this.cents,
    this.counterparty = '',
    this.purpose = '',
    this.reference = '',
  });

  /// The booking day.
  final DateTime date;

  /// Signed: negative is money going out.
  final int cents;

  /// Who was paid or who paid ("REWE Markt GmbH", "Arbeitgeber AG").
  final String counterparty;

  /// The remittance text ("Miete Oktober").
  final String purpose;

  /// The bank's own id of the booking, if the file has one.
  final String reference;

  bool get income => cents > 0;

  /// Identifies the booking when the same days are imported again (from
  /// an overlapping statement): the bank's id, or day, amount and texts.
  String get importId {
    if (reference.isNotEmpty) return 'ref:$reference';
    final text = _norm('$counterparty $purpose');
    return '${dayKey(date)}|$cents|${text.length > 60 ? text.substring(0, 60) : text}';
  }

  /// The note of the budget entry: who, and what for.
  String get note {
    final who = counterparty.trim();
    final what = purpose.replaceAll(RegExp(r'\s+'), ' ').trim();
    final text = who.isEmpty
        ? what
        : what.isEmpty
        ? who
        : '$who – $what';
    return text.length > 120 ? '${text.substring(0, 119)}…' : text;
  }
}

/// The file is neither a CSV export nor a CAMT statement Famio can read.
class BankFormatException implements Exception {
  const BankFormatException();
}

/// Reads a bank statement: CAMT.052/.053/.054 (ISO 20022 XML) or the CSV
/// export of a German bank (Sparkasse, Volksbank, DKB, ING, comdirect,
/// N26 …; columns are recognised by their names). Pending bookings are
/// left out. Throws [BankFormatException].
List<BankTransaction> parseBankStatement(List<int> bytes) {
  final text = _decode(bytes);
  final start = text.trimLeft();
  final list = start.startsWith('<') ? _camt(start) : _csv(text);
  // Newest first; same day in the file's order.
  final indexed = list.indexed.toList()
    ..sort((a, b) {
      final byDate = b.$2.date.compareTo(a.$2.date);
      return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
    });
  return [for (final (_, t) in indexed) t];
}

/// UTF-8, or (many German banks) Windows-1252/ISO-8859-1.
String _decode(List<int> bytes) {
  var text = '';
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    text = latin1.decode(bytes);
  }
  return text.startsWith('﻿') ? text.substring(1) : text;
}

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüß]+'), ' ').trim();

// --- CAMT ---------------------------------------------------------------

List<BankTransaction> _camt(String text) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } on XmlException {
    throw const BankFormatException();
  }
  final entries = doc.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'Ntry')
      .toList();
  if (entries.isEmpty &&
      !doc.descendants.whereType<XmlElement>().any(
        (e) => e.name.local.startsWith('BkToCstmr'),
      )) {
    throw const BankFormatException();
  }
  final result = <BankTransaction>[];
  for (final entry in entries) {
    final status = _text(entry, ['Sts', 'Cd']) ?? _text(entry, ['Sts']);
    if (status != null && status.toUpperCase() != 'BOOK') continue;
    final debit = _text(entry, ['CdtDbtInd'])?.toUpperCase() == 'DBIT';
    final date = _parseDate(
      _text(entry, ['BookgDt', 'Dt']) ??
          _text(entry, ['BookgDt', 'DtTm']) ??
          _text(entry, ['ValDt', 'Dt']) ??
          '',
    );
    if (date == null) continue;
    final reference =
        _text(entry, ['AcctSvcrRef']) ?? _text(entry, ['NtryRef']) ?? '';
    final details = [
      for (final d in _children(entry, 'NtryDtls')) ..._children(d, 'TxDtls'),
    ];
    String party(XmlElement? tx) {
      if (tx == null) return '';
      final related = _first(tx, 'RltdPties');
      if (related == null) return '';
      // Money out: the creditor was paid; money in: the debtor paid.
      final who = _first(related, debit ? 'Cdtr' : 'Dbtr');
      return who == null ? '' : _deep(who, 'Nm') ?? '';
    }

    String purpose(XmlElement? tx) => [
      if (tx != null)
        for (final r in _children(tx, 'RmtInf'))
          for (final u in _children(r, 'Ustrd')) u.innerText.trim(),
    ].where((s) => s.isNotEmpty).join(' ');

    final entryAmount = _amount(_text(entry, ['Amt']));
    final extra = _text(entry, ['AddtlNtryInf']) ?? '';
    // A batch (several transfers in one entry) with an amount per transfer.
    final split =
        details.length > 1 && details.every((d) => _txAmount(d) != null);
    for (final (i, tx) in (split ? details : [details.firstOrNull]).indexed) {
      final cents = split ? _txAmount(tx!)! : entryAmount;
      if (cents == null) continue;
      result.add(
        BankTransaction(
          date: date,
          cents: debit ? -cents : cents,
          counterparty: party(tx),
          purpose: switch (purpose(tx)) {
            '' => extra,
            final p => p,
          },
          reference: reference.isEmpty
              ? ''
              : split
              ? '$reference/$i'
              : reference,
        ),
      );
    }
  }
  return result;
}

int? _txAmount(XmlElement tx) =>
    _amount(_text(tx, ['AmtDtls', 'TxAmt', 'Amt']) ?? _text(tx, ['Amt']));

int? _amount(String? text) {
  final v = text == null ? null : double.tryParse(text.trim());
  return v == null ? null : (v * 100).round().abs();
}

Iterable<XmlElement> _children(XmlElement e, String name) =>
    e.childElements.where((c) => c.name.local == name);

XmlElement? _first(XmlElement e, String name) => _children(e, name).firstOrNull;

/// The text at [path] below [e] (local names, any namespace).
String? _text(XmlElement e, List<String> path) {
  XmlElement? at = e;
  for (final name in path) {
    at = at == null ? null : _first(at, name);
  }
  final t = at?.innerText.trim();
  return t == null || t.isEmpty || at!.childElements.isNotEmpty ? null : t;
}

/// The first [name] anywhere below [e].
String? _deep(XmlElement e, String name) {
  for (final d in e.descendants.whereType<XmlElement>()) {
    if (d.name.local == name && d.innerText.trim().isNotEmpty) {
      return d.innerText.trim();
    }
  }
  return null;
}

// --- CSV ----------------------------------------------------------------

/// Column names banks use, most specific first.
const _dateNames = [
  'buchungstag',
  'buchungsdatum',
  'buchung',
  'booking date',
  'date',
  'datum',
  'valutadatum',
  'wertstellung',
  'valuta',
];
const _amountNames = ['betrag', 'umsatz', 'amount'];
const _debitNames = ['soll', 'ausgang', 'debit', 'belastung'];
const _creditNames = ['haben', 'eingang', 'credit', 'gutschrift'];
const _signNames = ['soll/haben', 's/h', 'soll-haben'];
const _partyNames = [
  'beguenstigter/zahlungspflichtiger',
  'begünstigter/zahlungspflichtiger',
  'auftraggeber/empfänger',
  'auftraggeber / empfänger',
  'begünstigter / auftraggeber',
  // Volksbank: the first of the two is the account holder.
  'empfänger/zahlungspflichtiger',
  'auftraggeber/zahlungsempfänger',
  'empfänger/auftraggeber',
  'name zahlungsbeteiligter',
  'zahlungsempfänger',
  'payee',
  'partner name',
  'empfänger',
  'auftraggeber',
  'name',
];
// DKB: two columns, one per direction.
const _payerNames = ['zahlungspflichtige', 'zahlungspflichtiger'];
const _purposeNames = [
  'verwendungszweck',
  'vorgang/verwendungszweck',
  'payment reference',
  'buchungsdetails',
  'beschreibung',
  'description',
  'text',
];
const _kindNames = ['buchungstext', 'umsatztyp', 'transaction type', 'vorgang'];
// Sparkasse marks pending ones in "Info".
const _statusNames = ['status', 'info'];

final _letter = RegExp('[a-zäöüß]');

List<BankTransaction> _csv(String text) {
  final rows = _rows(text);
  // A line above the bookings may look like a header ("Sortierung;Datum
  // absteigend"): the header is the one with bookings below it.
  var header = false;
  for (var h = 0; h < rows.length && h < 40; h++) {
    final columns = [for (final c in rows[h]) c.trim().toLowerCase()];

    /// The column named exactly like one of [names], else the first that
    /// starts with one as a word ("Betrag (€)", not "Betragsart"), unless
    /// it matches [unless].
    int find(List<String> names, {List<int> not = const [], String? unless}) {
      for (final name in names) {
        for (var i = 0; i < columns.length; i++) {
          if (!not.contains(i) && columns[i] == name) return i;
        }
      }
      final skip = RegExp(
        'saldo|kontostand|fremd|foreign|original${unless == null ? '' : '|$unless'}',
      );
      for (final name in names) {
        for (var i = 0; i < columns.length; i++) {
          final c = columns[i];
          if (!not.contains(i) &&
              c.startsWith(name) &&
              !_letter.hasMatch(c.length > name.length ? c[name.length] : '') &&
              !skip.hasMatch(c)) {
            return i;
          }
        }
      }
      return -1;
    }

    final date = find(_dateNames, unless: 'text|zweck|art');
    if (date < 0) continue;
    final amount = find(_amountNames, unless: 'typ|art');
    final debit = amount < 0 ? find(_debitNames) : -1;
    final credit = amount < 0 ? find(_creditNames) : -1;
    if (amount < 0 && (debit < 0 || credit < 0)) continue;
    var sign = find(_signNames);
    // Volksbank: an unnamed column right of the amount with S or H.
    if (sign < 0 && amount >= 0 && amount + 1 < columns.length) {
      final marks = {
        for (final row in rows.skip(h + 1))
          if (row.length > amount + 1) row[amount + 1].trim().toUpperCase(),
      }..remove('');
      if (marks.isNotEmpty && marks.every((m) => m == 'S' || m == 'H')) {
        sign = amount + 1;
      }
    }
    final payer = find(_payerNames);
    final party = find(_partyNames, not: [payer]);
    final purpose = find(_purposeNames);
    final kind = find(_kindNames);
    final status = find(_statusNames);
    String cell(List<String> row, int i) =>
        i < 0 || i >= row.length ? '' : row[i].trim();

    final result = <BankTransaction>[];
    for (final row in rows.skip(h + 1)) {
      final day = _parseDate(cell(row, date));
      if (day == null) continue;
      final state = cell(row, status).toLowerCase();
      if (state.contains('vorgemerkt') || state.startsWith('pending')) {
        continue;
      }
      int? cents;
      if (amount >= 0) {
        cents = _parseAmount(cell(row, amount));
        final s = cell(row, sign).toUpperCase();
        if (cents != null && s == 'S') cents = -cents.abs();
        if (cents != null && s == 'H') cents = cents.abs();
      } else {
        final out = _parseAmount(cell(row, debit));
        final inn = _parseAmount(cell(row, credit));
        cents = (inn ?? 0).abs() - (out ?? 0).abs();
        if (out == null && inn == null) cents = null;
      }
      if (cents == null || cents == 0) continue;
      final who = payer >= 0 && cents > 0 && cell(row, payer).isNotEmpty
          ? cell(row, payer)
          : cell(row, party);
      result.add(
        BankTransaction(
          date: day,
          cents: cents,
          counterparty: who,
          purpose: switch (cell(row, purpose)) {
            '' => cell(row, kind),
            final p => p,
          },
        ),
      );
    }
    header = true;
    if (result.isNotEmpty) return result;
  }
  if (header) return [];
  throw const BankFormatException();
}

/// The cells of each line; the separator (; , or tab) is the one most
/// common outside quotes.
List<List<String>> _rows(String text) {
  final sample = text.length > 4000 ? text.substring(0, 4000) : text;
  final unquoted = sample.replaceAll(RegExp('"[^"]*"'), '');
  final separator = [';', ',', '\t'].reduce(
    (a, b) =>
        a.allMatches(unquoted).length >= b.allMatches(unquoted).length ? a : b,
  );
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == separator) {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      if (row.any((c) => c.trim().isNotEmpty)) rows.add(row);
      row = [];
    } else {
      cell.write(ch);
    }
  }
  row.add(cell.toString());
  if (row.any((c) => c.trim().isNotEmpty)) rows.add(row);
  return rows;
}

/// "-1.234,56", "1234.56", "12,50 €", "12,50-" (sign last) → cents.
int? _parseAmount(String text) {
  var t = text.replaceAll(RegExp(r'[\s €$£]|EUR', caseSensitive: false), '');
  if (t.isEmpty) return null;
  var negative = false;
  if (t.endsWith('-')) {
    negative = true;
    t = t.substring(0, t.length - 1);
  }
  if (t.startsWith('-') || t.startsWith('−')) {
    negative = true;
    t = t.substring(1);
  } else if (t.startsWith('+')) {
    t = t.substring(1);
  }
  final comma = t.lastIndexOf(',');
  final dot = t.lastIndexOf('.');
  if (comma > dot) {
    t = t.replaceAll('.', '').replaceAll(',', '.');
  } else {
    t = t.replaceAll(',', '');
  }
  final v = double.tryParse(t);
  if (v == null) return null;
  final cents = (v * 100).round();
  return negative ? -cents : cents;
}

/// 31.12.2026, 31.12.26, 2026-12-31 (also with a time), 31/12/2026.
DateTime? _parseDate(String text) {
  final t = text.trim();
  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(t);
  if (iso != null) {
    return _day(int.parse(iso[1]!), int.parse(iso[2]!), int.parse(iso[3]!));
  }
  final m = RegExp(r'^(\d{1,2})[./](\d{1,2})[./](\d{2,4})$').firstMatch(t);
  if (m == null) return null;
  var year = int.parse(m[3]!);
  if (year < 100) year += 2000;
  return _day(year, int.parse(m[2]!), int.parse(m[1]!));
}

DateTime? _day(int y, int m, int d) =>
    m < 1 || m > 12 || d < 1 || d > 31 ? null : DateTime(y, m, d);

// --- categories and duplicates -------------------------------------------

/// Words that point to a budget category, in Famio's default categories.
const _hints = <(String, List<String>)>[
  ('Gehalt', ['gehalt', 'lohn', 'bezüge', 'bezuege', 'salary', 'nómina']),
  ('Kindergeld', ['kindergeld', 'familienkasse']),
  ('Elterngeld', ['elterngeld']),
  (
    'Lebensmittel',
    [
      'rewe',
      'edeka',
      'aldi',
      'lidl',
      'netto',
      'penny',
      'kaufland',
      'real ',
      'tegut',
      'globus',
      'norma',
      'bäckerei',
      'baeckerei',
      'metzgerei',
      'supermarkt',
      'denns',
      'alnatura',
      'bio company',
      'hellofresh',
    ],
  ),
  (
    'Haushalt',
    [
      'dm-drogerie',
      'dm drogerie',
      'rossmann',
      'müller',
      'ikea',
      'obi ',
      'hornbach',
      'bauhaus',
      'toom',
      'amazon',
      'otto',
    ],
  ),
  (
    'Wohnen',
    [
      'miete',
      'nebenkosten',
      'hausgeld',
      'stadtwerke',
      'strom',
      'gas ',
      'wasser',
      'vattenfall',
      'eon',
      'e.on',
      'enbw',
      'telekom',
      'vodafone',
      'o2',
      '1&1',
      'rundfunk',
      'grundsteuer',
    ],
  ),
  (
    'Mobilität',
    [
      'tankstelle',
      'aral',
      'shell',
      'esso',
      'jet ',
      'total',
      'deutsche bahn',
      'db vertrieb',
      'bahn',
      'bvg',
      'hvv',
      'mvg',
      'vbb',
      'rmv',
      'kvb',
      'deutschlandticket',
      'parken',
      'parkhaus',
      'kfz',
      'werkstatt',
      'atu',
      'sixt',
      'flixbus',
      'uber',
    ],
  ),
  (
    'Kinder',
    [
      'kita',
      'kindergarten',
      'schule',
      'hort',
      'musikschule',
      'spielwaren',
      'mytoys',
      'babywalz',
      'windeln',
    ],
  ),
  (
    'Gesundheit',
    [
      'apotheke',
      'arzt',
      'zahnarzt',
      'praxis',
      'krankenhaus',
      'optiker',
      'fielmann',
      'physio',
    ],
  ),
  (
    'Versicherungen',
    [
      'versicherung',
      'huk',
      'allianz',
      'axa',
      'ergo',
      'debeka',
      'devk',
      'signal iduna',
      'generali',
      'krankenkasse',
      'aok',
      'barmer',
      'tk ',
    ],
  ),
  (
    'Kleidung',
    [
      'zalando',
      'h&m',
      'c&a',
      'primark',
      'kik',
      'deichmann',
      'tchibo',
      'about you',
      'peek',
    ],
  ),
  (
    'Freizeit',
    [
      'netflix',
      'spotify',
      'disney',
      'kino',
      'cinema',
      'theater',
      'museum',
      'zoo',
      'schwimmbad',
      'restaurant',
      'lieferando',
      'steam',
      'playstation',
      'urlaub',
      'hotel',
      'booking.com',
      'airbnb',
    ],
  ),
];

/// The category for [t]: what the family chose for the same payee before
/// (latest first), else a word in its texts, else "Sonstiges" or
/// "Sonstige Einnahmen".
String suggestBudgetCategory(BankTransaction t, List<BudgetEntry> history) {
  final payee = _firstWord(t.counterparty.isEmpty ? t.purpose : t.counterparty);
  if (payee.isNotEmpty) {
    final same = [
      for (final e in history)
        if (e.income == t.income && _firstWord(e.note) == payee) e,
    ]..sort((a, b) => b.date.compareTo(a.date));
    if (same.isNotEmpty) return same.first.category;
  }
  final text = ' ${_norm('${t.counterparty} ${t.purpose}')} ';
  final allowed = t.income ? incomeCategories : expenseCategories;
  for (final (category, words) in _hints) {
    if (!allowed.contains(category)) continue;
    if (words.any((w) => text.contains(w.endsWith(' ') ? ' $w' : w))) {
      return category;
    }
  }
  return t.income ? 'Sonstige Einnahmen' : 'Sonstiges';
}

/// The first word of at least three letters ("rewe" of "REWE Markt
/// GmbH").
String _firstWord(String text) =>
    _norm(text).split(' ').firstWhere((w) => w.length >= 3, orElse: () => '');

enum BankDuplicate {
  /// Imported before (same booking).
  imported,

  /// An entry of the same amount and direction within three days (or a
  /// monthly one in that month): maybe entered by hand.
  likely,
}

/// Whether [t] is already in the budget.
BankDuplicate? bankDuplicate(BankTransaction t, List<BudgetEntry> entries) {
  if (entries.any((e) => e.importId == t.importId)) {
    return BankDuplicate.imported;
  }
  for (final e in entries) {
    if (e.importId != null ||
        e.income != t.income ||
        e.cents != t.cents.abs()) {
      continue;
    }
    // The rent entered as monthly counts in every month.
    if (e.monthly
        ? e.inMonth(t.date)
        : e.date.difference(t.date).inDays.abs() <= 3) {
      return BankDuplicate.likely;
    }
  }
  return null;
}
