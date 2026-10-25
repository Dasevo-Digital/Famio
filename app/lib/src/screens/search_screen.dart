import 'dart:async';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../data/search.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import 'chat_screens.dart';
import 'contacts_screens.dart';
import 'event_editor.dart';
import 'home_shell.dart';
import 'deferred_sections.dart';
import 'notes_screen.dart';
import 'inbox_screen.dart';
import 'pantry_screens.dart';
import 'shopping_screens.dart';
import 'tasks_screen.dart';
import '../l10n.dart';

/// Searches everything on this device: events, tasks, shopping, recipes,
/// documents, contacts, chat, pantry, medications and the family inbox.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const _searchDelay = Duration(milliseconds: 250);
  final _query = TextEditingController();
  Timer? _searchTimer;
  StreamSubscription<Set<String>>? _changes;
  SyncEngine? _listenedEngine;
  List<SearchHit> _hits = const [];
  var _searchPending = false;

  void _searchChanged(String value, {bool immediately = false}) {
    _searchTimer?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _hits = const [];
        _searchPending = false;
      });
      return;
    }
    setState(() {
      _hits = const [];
      _searchPending = true;
    });
    void search() {
      if (!mounted || _query.text != value) return;
      final state = AppScope.of(context);
      final engine = state.engine!;
      final sections = sectionsFor(
        engine.myRole,
        hidden: state.hiddenModules,
      ).toSet();
      final hits = searchFamily(engine, value, sections: sections);
      if (!mounted || _query.text != value) return;
      setState(() {
        _hits = hits;
        _searchPending = false;
      });
    }

    if (immediately) {
      search();
    } else {
      _searchTimer = Timer(_searchDelay, search);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final engine = AppScope.of(context).engine;
    if (identical(engine, _listenedEngine)) return;
    unawaited(_changes?.cancel());
    _listenedEngine = engine;
    _changes = engine?.changes.listen((_) {
      if (mounted && _query.text.trim().isNotEmpty) {
        _searchChanged(_query.text, immediately: true);
      }
    });
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    unawaited(_changes?.cancel());
    _query.dispose();
    super.dispose();
  }

  Future<void> _open(SyncEngine engine, SearchHit hit) async {
    switch (hit.kind) {
      case SearchKind.event:
        final e = engine.events.where((e) => e.id == hit.id).firstOrNull;
        if (e == null) return;
        final now = DateTime.now();
        final next =
            e
                .occurrencesBetween(now, now.add(const Duration(days: 400)))
                .firstOrNull ??
            Occurrence(e, e.start, e.end);
        await showEventEditor(context, occurrence: next);
      case SearchKind.task:
        final t = engine.tasks.where((t) => t.id == hit.id).firstOrNull;
        if (t != null) await showTaskEditor(context, task: t);
      case SearchKind.shopping:
        final r = engine.record(Collections.shoppingItems, hit.id);
        if (r == null) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                ShoppingListScreen(listId: ShoppingItem.fromRecord(r).listId),
          ),
        );
      case SearchKind.pantry:
        final p = engine.pantryItems.where((p) => p.id == hit.id).firstOrNull;
        if (p != null) {
          await showPantryEditor(context, initial: p, existing: true);
        }
      case SearchKind.recipe:
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => recipePage(hit.id)));
      case SearchKind.document:
        final nav = FamioNav.of(context);
        Navigator.of(context).pop();
        nav.go(FamioSection.documents);
        return;
      case SearchKind.contact:
        final c = engine.contacts.where((c) => c.id == hit.id).firstOrNull;
        if (c != null) await showContactEditor(context, existing: c);
      case SearchKind.medication:
        final m = engine.medications.where((m) => m.id == hit.id).firstOrNull;
        if (m != null) await openMedicationEditor(context, m);
      case SearchKind.note:
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const NotesScreen()));
      case SearchKind.chat:
        final r = engine.record(Collections.chatMessages, hit.id);
        if (r == null) return;
        final chatId = ChatMessage.fromRecord(r).chatId;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                ChatScreen(chatId: chatId, title: _chatTitle(engine, chatId)),
          ),
        );
      case SearchKind.inbox:
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const InboxScreen()));
    }
    if (mounted) _searchChanged(_query.text, immediately: true);
  }

  static String _chatTitle(SyncEngine engine, String chatId) {
    if (chatId == ChatIds.family) return tr.settingsFamily;
    for (final m in engine.members) {
      if (ChatIds.direct(engine.memberId, m.id) == chatId) {
        return m.displayName;
      }
    }
    return tr.sectionChat;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final engine = state.engine!;
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final day = DateFormat.yMMMd(appLanguage);
    return SectionPage(
      section: FamioSection.home,
      title: tr.commonSearch,
      subtitle: tr.searchEverythingDeviceAlsoOffline,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(AppIcons.magnifyingGlass),
                    hintText: tr.searchEventTaskRecipeContact,
                    suffixIcon: _query.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(AppIcons.x),
                            tooltip: tr.settingsStorageClear,
                            onPressed: () {
                              _query.clear();
                              _searchChanged('');
                            },
                          ),
                  ),
                  onChanged: _searchChanged,
                  onSubmitted: (value) =>
                      _searchChanged(value, immediately: true),
                ),
              ),
              Expanded(
                child: _query.text.trim().isEmpty
                    ? const SizedBox.shrink()
                    : _searchPending
                    ? const SizedBox.shrink()
                    : _hits.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          tr.commonNothingFound,
                          style: theme.textTheme.bodyMedium,
                        ),
                      )
                    : ListView(
                        padding: EdgeInsets.only(
                          bottom: listBottomPadding(context),
                        ),
                        children: [
                          for (final kind in SearchKind.values)
                            if (_hits.any((h) => h.kind == kind)) ...[
                              ListHeading(
                                kind.label,
                                color: c.strong(kind.section),
                              ),
                              for (final h in _hits.where(
                                (h) => h.kind == kind,
                              ))
                                ListTile(
                                  leading: Icon(
                                    kind.section.icon,
                                    color: c.strong(kind.section),
                                  ),
                                  title: Text(
                                    h.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    [
                                      if (kind == SearchKind.chat)
                                        _chatTitle(engine, h.detail)
                                      else if (h.detail.isNotEmpty)
                                        h.detail,
                                      if (h.at != null) day.format(h.at!),
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () => _open(engine, h),
                                ),
                            ],
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
