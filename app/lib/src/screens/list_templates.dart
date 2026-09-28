import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import 'shopping_screens.dart';

/// Picks a saved or built-in template and creates a list from it.
Future<void> showTemplatePicker(BuildContext context) async {
  final engine = AppScope.engineOf(context);
  final navigator = Navigator.of(context);
  final picked = await showModalBottomSheet<ListTemplate>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _TemplateSheet(engine: engine),
  );
  if (picked == null) return;
  final id = engine.listFromTemplate(picked);
  navigator.push(
    MaterialPageRoute<void>(builder: (_) => ShoppingListScreen(listId: id)),
  );
}

class _TemplateSheet extends StatefulWidget {
  const _TemplateSheet({required this.engine});

  final SyncEngine engine;

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
              'Liste aus Vorlage',
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
