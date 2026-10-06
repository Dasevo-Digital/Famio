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
import 'meals_screens.dart';
import 'notes_screen.dart';
import 'medication_screens.dart';
import 'pantry_screens.dart';
import 'shopping_screens.dart';
import 'tasks_screen.dart';

/// Searches everything on this device: events, tasks, shopping, recipes,
/// documents, contacts, chat, pantry and medications.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
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
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RecipeScreen(recipeId: hit.id),
          ),
        );
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
        if (m != null) await showMedicationEditor(context, medication: m);
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
    }
    if (mounted) setState(() {});
  }

  static String _chatTitle(SyncEngine engine, String chatId) {
    if (chatId == ChatIds.family) return 'Familie';
    for (final m in engine.members) {
      if (ChatIds.direct(engine.memberId, m.id) == chatId) {
        return m.displayName;
      }
    }
    return 'Chat';
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final engine = state.engine!;
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final sections = sectionsFor(
      engine.myRole,
      hidden: state.hiddenModules,
    ).toSet();
    final hits = searchFamily(engine, _query.text, sections: sections);
    final day = DateFormat('d. MMM y', 'de');
    return SectionPage(
      section: FamioSection.home,
      title: 'Suchen',
      subtitle: 'Alles auf diesem Gerät, auch offline',
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
                    hintText: 'Termin, Aufgabe, Rezept, Kontakt …',
                    suffixIcon: _query.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(AppIcons.x),
                            tooltip: 'Leeren',
                            onPressed: () => setState(_query.clear),
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              Expanded(
                child: _query.text.trim().isEmpty
                    ? const SizedBox.shrink()
                    : hits.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Nichts gefunden.',
                          style: theme.textTheme.bodyMedium,
                        ),
                      )
                    : ListView(
                        padding: EdgeInsets.only(
                          bottom: listBottomPadding(context),
                        ),
                        children: [
                          for (final kind in SearchKind.values)
                            if (hits.any((h) => h.kind == kind)) ...[
                              ListHeading(
                                kind.label,
                                color: c.strong(kind.section),
                              ),
                              for (final h in hits.where((h) => h.kind == kind))
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
