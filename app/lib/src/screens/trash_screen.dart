import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});
  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  final _items = <TrashEntry>[];
  int? _next;
  var _loading = true;
  String? _error;
  String? _restoring;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool more = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final engine = AppScope.engineOf(context);
      await engine.sync();
      final result = await engine.api.trash(before: more ? _next : null);
      if (!mounted) return;
      setState(() {
        if (!more) _items.clear();
        _items.addAll(result.items);
        _next = result.next;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restore(TrashEntry entry) async {
    setState(() {
      _restoring = entry.id;
      _error = null;
    });
    try {
      final engine = AppScope.engineOf(context);
      await engine.api.restoreTrash(entry.id);
      await engine.sync();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.trashRestored)));
      await _load();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _restoring = null);
    }
  }

  @override
  Widget build(BuildContext context) => SectionPage(
    section: FamioSection.settings,
    title: tr.trashTitle,
    subtitle: tr.trashHint,
    maxBodyWidth: 900,
    actions: [
      IconButton(
        tooltip: tr.commonRefresh,
        icon: const Icon(AppIcons.arrowsClockwise),
        onPressed: _loading || _restoring != null ? null : () => _load(),
      ),
    ],
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          TextButton(
            onPressed: _loading ? null : () => _load(),
            child: Text(tr.commonRetry),
          ),
        ],
        if (_loading) const Center(child: CircularProgressIndicator()),
        if (!_loading && _error == null && _items.isEmpty) Text(tr.trashEmpty),
        for (final item in _items)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SoftCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title.isEmpty ? tr.commonEntry : item.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '${switch (item.record.collection) {
                      Collections.tasks => tr.assignmentTask,
                      Collections.events => tr.commonEvent,
                      Collections.notes => tr.commonNote,
                      _ => tr.commonDocument,
                    }} · ${tr.trashExpires(DateFormat.yMd(appLanguage).format(item.expiresAt))}',
                  ),
                  const SizedBox(height: 8),
                  if (item.canRestore)
                    FilledButton.icon(
                      onPressed: _loading || _restoring != null
                          ? null
                          : () => _restore(item),
                      icon: const Icon(AppIcons.arrowsClockwise),
                      label: Text(tr.trashRestore),
                    ),
                ],
              ),
            ),
          ),
        if (!_loading && _next != null)
          TextButton(
            onPressed: () => _load(more: true),
            child: Text(tr.trashMore),
          ),
      ],
    ),
  );
}
