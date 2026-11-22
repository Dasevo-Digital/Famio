import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../design/palette.dart';
import 'birthdays.dart';
import 'family_data.dart';
import 'family_extras.dart';
import '../l10n.dart';

/// What a search hit is.
enum SearchKind {
  event(FamioSection.calendar),
  task(FamioSection.tasks),
  shopping(FamioSection.shopping),
  recipe(FamioSection.meals),
  document(FamioSection.documents),
  contact(FamioSection.contacts),
  chat(FamioSection.chat),
  pantry(FamioSection.shopping),
  medication(FamioSection.health),
  note(FamioSection.home),
  inbox(FamioSection.home);

  const SearchKind(this.section);

  String get label => switch (this) {
    event => tr.commonEvents,
    task => tr.sectionTasks,
    shopping => tr.sectionShopping,
    recipe => tr.mealsRecipes,
    document => tr.sectionDocuments,
    contact => tr.sectionContacts,
    chat => tr.sectionChat,
    pantry => tr.conflictsPantry,
    medication => tr.commonMedications,
    note => tr.commonPinboard,
    inbox => tr.inboxTitle,
  };

  final FamioSection section;
}

class SearchHit {
  const SearchHit({
    required this.kind,
    required this.id,
    required this.title,
    this.detail = '',
    this.at,
    this.score = 1,
  });

  final SearchKind kind;
  final String id;
  final String title;
  final String detail;

  /// When it happens or happened, for the order among equal hits.
  final DateTime? at;
  final int score;
}

/// Lower case without umlauts and accents, so "muell" finds "Müll".
String foldForSearch(String s) {
  const map = {
    'ä': 'a',
    'ö': 'o',
    'ü': 'u',
    'ß': 'ss',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'á': 'a',
    'à': 'a',
    'ó': 'o',
    'ò': 'o',
    'í': 'i',
    'ú': 'u',
    'ç': 'c',
  };
  final lower = s.toLowerCase();
  final out = StringBuffer();
  for (final ch in lower.split('')) {
    out.write(map[ch] ?? ch);
  }
  // "ae" typed for "ä" matches too.
  return out
      .toString()
      .replaceAll('ae', 'a')
      .replaceAll('oe', 'o')
      .replaceAll('ue', 'u');
}

/// About 60 characters of [text] around the first of [words] (folded
/// like [foldForSearch]), with … where cut; null if it is not in there.
String? textSnippet(String text, List<String> words) {
  if (text.isEmpty || words.isEmpty) return null;
  final flat = _flat(text);
  return _snippet(flat, foldForSearch(flat), words);
}

String _flat(String text) => text.replaceAll(RegExp(r'\s+'), ' ');

/// [textSnippet] of [flat] (whitespace made single spaces), whose folded
/// form is [folded].
String? _snippet(String flat, String folded, List<String> words) {
  if (flat.isEmpty || words.isEmpty) return null;
  final at = folded.indexOf(words.first);
  if (at < 0) return null;
  // Folding changes lengths (ß, ae …): the shortest start of the text that
  // folds to at least [at] characters ends where the word begins.
  var low = 0, high = flat.length;
  while (low < high) {
    final mid = (low + high) ~/ 2;
    if (foldForSearch(flat.substring(0, mid)).length < at) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  final start = (low - 25).clamp(0, flat.length);
  final end = (start + 60).clamp(0, flat.length);
  return [
    if (start > 0) '…',
    flat.substring(start, end).trim(),
    if (end < flat.length) '…',
  ].join();
}

/// A long text of a record folded once per version of the record: a
/// changed record is a new object, so nothing goes stale.
final _documentTexts = Expando<({String flat, String folded})>('search');

/// A chat message read and folded once per version of its record.
final _chatTexts =
    Expando<
      ({ChatMessage message, String title, String foldedTitle, String folded})
    >('search chat');

/// How many texts search read and folded (documents, chat messages), for
/// tests: each version of a record only once.
@visibleForTesting
int debugSearchTextsFolded = 0;

/// How many snippets search cut out of documents, for tests: only for
/// hits.
@visibleForTesting
int debugSearchSnippets = 0;

/// Everything on this device that matches all words of [query], best and
/// newest first. Only what the member sees in the app ([sections]); nothing
/// leaves the device.
List<SearchHit> searchFamily(
  SyncEngine engine,
  String query, {
  required Set<FamioSection> sections,
  int perKind = 20,
}) {
  final words = foldForSearch(
    query,
  ).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const [];

  final hits = <SearchHit>[];

  /// [foldedTitle] and [folded] are what is already folded; [describe]
  /// works out the detail only for a hit.
  void consider(
    SearchKind kind,
    String id,
    String title,
    List<String> more, {
    String detail = '',
    String Function()? describe,
    DateTime? at,
    String? foldedTitle,
    String folded = '',
  }) {
    final t = foldedTitle ?? foldForSearch(title);
    final all = more.isEmpty
        ? '$t $folded'
        : '$t ${foldForSearch(more.join(' '))} $folded';
    if (!words.every(all.contains)) return;
    final score = t.startsWith(words.first)
        ? 3
        : words.every(t.contains)
        ? 2
        : 1;
    hits.add(
      SearchHit(
        kind: kind,
        id: id,
        title: title.isEmpty ? tr.commonUntitled : title,
        detail: describe?.call() ?? detail,
        at: at,
        score: score,
      ),
    );
  }

  bool shows(SearchKind k) => sections.contains(k.section);

  if (shows(SearchKind.event)) {
    // Own appointments, subscribed and connected calendars, as in the
    // calendar.
    for (final e in [...engine.events, ...engine.externalEvents]) {
      consider(
        SearchKind.event,
        e.id,
        e.title,
        [e.location, e.notes],
        detail: e.location,
        // Else where it comes from: only for a hit.
        describe: e.location.isEmpty && e.sourceId != null
            ? () => engine.calendarSubscription(e.sourceId)?.name ?? ''
            : null,
        at: e.start,
      );
    }
    final today = DateTime.now();
    for (final b in familyBirthdays(engine)) {
      consider(
        SearchKind.event,
        b.sourceId,
        '🎂 ${b.name}',
        [tr.commonBirthday],
        detail: tr.commonBirthday,
        at: b.next(today),
      );
    }
  }
  if (shows(SearchKind.task)) {
    for (final t in engine.tasks) {
      consider(
        SearchKind.task,
        t.id,
        t.title,
        [t.notes],
        detail: t.done ? tr.commonDoneLower : '',
        at: t.due ?? t.createdAt,
      );
    }
  }
  if (shows(SearchKind.shopping)) {
    final lists = {for (final l in engine.shoppingLists) l.id: l.name};
    for (final listId in lists.keys) {
      for (final i in engine.shoppingItems(listId)) {
        consider(
          SearchKind.shopping,
          i.id,
          i.name,
          [i.quantity, i.category],
          detail: [
            lists[listId]!,
            i.quantity,
          ].where((s) => s.isNotEmpty).join(' · '),
        );
      }
    }
    for (final p in engine.pantryItems) {
      consider(SearchKind.pantry, p.id, p.name, [p.brand], detail: p.brand);
    }
  }
  if (shows(SearchKind.recipe)) {
    for (final r in engine.recipes) {
      consider(SearchKind.recipe, r.id, r.title, [
        ...r.tags,
        for (final i in r.ingredients) i.name,
      ], detail: r.tags.join(', '));
    }
  }
  if (shows(SearchKind.document)) {
    for (final collection in [
      Collections.documents,
      Collections.externalDocuments,
    ]) {
      for (final r in engine.records(collection)) {
        final d = FamilyDocument.fromRecord(r);
        // Recognised texts are long: folded once per version.
        final text = d.content.isEmpty
            ? null
            : _documentTexts[r] ??= () {
                debugSearchTextsFolded++;
                final flat = _flat(d.content);
                return (flat: flat, folded: foldForSearch(flat));
              }();
        consider(
          SearchKind.document,
          d.id,
          d.title,
          [d.notes, d.category.label],
          folded: text?.folded ?? '',
          // Found only in its text: where, so one sees why.
          describe: () {
            final inMeta = words.every(
              foldForSearch(
                '${d.title} ${d.notes} ${d.category.label}',
              ).contains,
            );
            if (inMeta || text == null) return d.category.label;
            debugSearchSnippets++;
            return [
              d.category.label,
              ?_snippet(text.flat, text.folded, words),
            ].join(' · ');
          },
        );
      }
    }
  }
  if (shows(SearchKind.contact)) {
    for (final c in engine.contacts) {
      consider(SearchKind.contact, c.id, c.name, [
        c.phone,
        c.email,
        c.address,
        c.note,
        c.role.label,
      ], detail: c.role.label);
    }
  }
  if (shows(SearchKind.medication)) {
    for (final m in engine.medications) {
      consider(SearchKind.medication, m.id, m.name, [
        m.personName,
        m.notes,
      ], detail: m.personName);
    }
  }
  if (shows(SearchKind.chat)) {
    for (final r in engine.records(Collections.chatMessages)) {
      // Read and folded once per version, not on every search.
      final chat = _chatTexts[r] ??= () {
        debugSearchTextsFolded++;
        final m = ChatMessage.fromRecord(r);
        final title = m.text.split('\n').first;
        return (
          message: m,
          title: title,
          foldedTitle: foldForSearch(title),
          folded: foldForSearch(m.text),
        );
      }();
      final m = chat.message;
      if (m.text.isEmpty) continue;
      consider(
        SearchKind.chat,
        m.id,
        chat.title,
        const [],
        foldedTitle: chat.foldedTitle,
        folded: chat.folded,
        detail: m.chatId,
        at: m.sentAt,
      );
    }
  }

  if (shows(SearchKind.note)) {
    for (final n in engine.notes) {
      consider(
        SearchKind.note,
        n.id,
        n.title,
        [n.text],
        detail: n.text.split('\n').first,
        at: n.updatedAt,
      );
    }
  }
  if (shows(SearchKind.inbox)) {
    for (final item in engine.inboxItems) {
      consider(
        SearchKind.inbox,
        item.id,
        item.title,
        [item.text, ...item.files.map((file) => file.name)],
        detail: item.text.split('\n').first,
        at: item.createdAt,
      );
    }
  }

  hits.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return (b.at ?? DateTime(0)).compareTo(a.at ?? DateTime(0));
  });
  final perKindCount = <SearchKind, int>{};
  return [
    for (final h in hits)
      if ((perKindCount[h.kind] = (perKindCount[h.kind] ?? 0) + 1) <= perKind)
        h,
  ];
}
