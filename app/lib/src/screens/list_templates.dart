import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import 'shopping_screens.dart';

/// Picks a saved or built-in template and creates a list from it.
Future<void> showTemplatePicker(BuildContext context) async {
  final engine = AppScope.engineOf(context);
  final navigator = Navigator.of(context);
  final picked = await pickListTemplate(context);
  if (picked == null) return;
  final id = engine.listFromTemplate(picked);
  navigator.push(
    MaterialPageRoute<void>(builder: (_) => ShoppingListScreen(listId: id)),
  );
}

/// A saved or built-in template, or null.
Future<ListTemplate?> pickListTemplate(
  BuildContext context, {
  String title = 'Liste aus Vorlage',
}) => showModalBottomSheet<ListTemplate>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) =>
      _TemplateSheet(engine: AppScope.engineOf(context), title: title),
);

class _TemplateSheet extends StatefulWidget {
  const _TemplateSheet({required this.engine, required this.title});

  final SyncEngine engine;
  final String title;

  @override
  State<_TemplateSheet> createState() => _TemplateSheetState();
}

class _TemplateSheetState extends State<_TemplateSheet> {
  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final own = widget.engine.listTemplates;
    final ownNames = {for (final t in own) t.name};
    final builtIn = [
      for (final t in builtInTemplates)
        if (!ownNames.contains(t.name)) t,
    ];
    Widget tile(ListTemplate t, {required bool saved}) => ListTile(
      leading: Text(t.emoji, style: const TextStyle(fontSize: 26)),
      title: Text(t.name),
      subtitle: Text('${t.items.length} Einträge'),
      onTap: () => Navigator.pop(context, t),
      trailing: saved
          ? IconButton(
              tooltip: 'Vorlage löschen',
              icon: Icon(AppIcons.trash, color: c.danger),
              onPressed: () =>
                  setState(() => widget.engine.deleteListTemplate(t.id)),
            )
          : null,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Text(
              widget.title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Eigene Vorlagen speichert ihr in einer Liste über ⋮ → „Als '
              'Vorlage speichern“.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (own.isNotEmpty) ...[
            const ListHeading('Eure Vorlagen'),
            for (final t in own) tile(t, saved: true),
          ],
          if (builtIn.isNotEmpty) ...[
            const ListHeading('Vorschläge'),
            for (final t in builtIn) tile(t, saved: false),
          ],
          if (own.isEmpty && builtIn.isEmpty)
            EmptyHint(
              icon: AppIcons.template,
              color: c.strong(FamioSection.shopping),
              text: 'Keine Vorlagen.',
            ),
        ],
      ),
    );
  }
}

/// In a trip's editor: its packing list with progress, or a button to
/// create one from a template for the chosen members.
class PackingListTile extends StatelessWidget {
  const PackingListTile({super.key, required this.event});

  final CalendarEvent event;

  Future<void> _create(BuildContext context, SyncEngine engine) async {
    final navigator = Navigator.of(context);
    final template = await pickListTemplate(
      context,
      title: 'Packliste aus Vorlage',
    );
    if (template == null || !context.mounted) return;
    final people = [
      for (final m in engine.members)
        if (!m.isGuest && !m.isService) m,
    ];
    final chosen = {
      for (final m in people)
        if (event.memberIds.isEmpty || event.memberIds.contains(m.id)) m.id,
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Wer packt?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Jede Person bekommt ihre eigenen Sachen; Ausweise, '
                'Ladegeräte & Co. stehen nur einmal drauf.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in people)
                    FilterChip(
                      avatar: MemberAvatar(m, radius: 10),
                      label: Text(m.displayName),
                      selected: chosen.contains(m.id),
                      onSelected: (on) => setState(
                        () => on ? chosen.add(m.id) : chosen.remove(m.id),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Anlegen'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final id = engine.packingListFor(
      event,
      template,
      memberIds: [
        for (final m in people)
          if (chosen.contains(m.id)) m.id,
      ],
    );
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => ShoppingListScreen(listId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      collections: const {Collections.shoppingLists, Collections.shoppingItems},
      builder: (context, engine) {
        final list = engine.packingListOf(event.id);
        if (list == null) {
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(AppIcons.luggage),
            title: const Text('Packliste anlegen'),
            subtitle: const Text(
              'Aus einer Vorlage, je Person – mit Erinnerung am Vorabend',
            ),
            onTap: () => _create(context, engine),
          );
        }
        final items = engine.shoppingItems(list.id);
        final packed = items.where((i) => i.checked).length;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(AppIcons.luggage),
          title: const Text('Packliste'),
          subtitle: Text('$packed von ${items.length} eingepackt'),
          trailing: const Icon(AppIcons.caretRight),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ShoppingListScreen(listId: list.id),
            ),
          ),
        );
      },
    );
  }
}
