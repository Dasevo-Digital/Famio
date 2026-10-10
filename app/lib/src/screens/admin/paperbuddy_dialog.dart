part of '../admin_screens.dart';

/// Admins connect the family's PaperBuddy: documents with a tag appear
/// under Documents, read-only, with their deadlines.
Future<void> showPaperBuddyDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _PaperBuddyDialog(),
);

class _PaperBuddyDialog extends StatefulWidget {
  const _PaperBuddyDialog();

  @override
  State<_PaperBuddyDialog> createState() => _PaperBuddyDialogState();
}

class _PaperBuddyDialogState extends State<_PaperBuddyDialog> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  final _tag = TextEditingController(text: 'Familie');
  final _members = <String>{};
  Map<String, Object?> _info = const {};
  String? _error;
  var _loading = true;
  var _busy = false;

  FamioApiClient get _api => AppScope.read(context).engine!.api;
  bool get _connected => _info['connected'] == true;

  @override
  void initState() {
    super.initState();
    _run(_api.paperBuddy, loading: true);
  }

  @override
  void dispose() {
    for (final c in [_url, _token, _tag]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply(Map<String, Object?> json) {
    _info = json;
    if (json['connected'] != true) return;
    _url.text = json['url'] as String? ?? '';
    _tag.text = json['tag'] as String? ?? 'Familie';
    _members
      ..clear()
      ..addAll([for (final m in json['memberIds'] as List? ?? const []) '$m']);
    _token.clear();
  }

  Future<bool> _run(
    Future<Map<String, Object?>> Function() call, {
    bool loading = false,
  }) async {
    setState(() {
      _busy = !loading;
      _error = null;
    });
    try {
      final json = await call();
      if (mounted) setState(() => _apply(json));
      return true;
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final ok = await _run(
      () => _api.savePaperBuddy(
        url: _url.text.trim(),
        token: _token.text.trim(),
        tag: _tag.text.trim(),
        memberIds: _members.toList(),
      ),
    );
    if (ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.adminPaperBuddySaved)));
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr.adminPaperBuddyRemove),
        content: Text(tr.adminPaperBuddyRemoveText),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(tr.commonRemove),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _run(_api.deletePaperBuddy);
  }

  String? get _status {
    final sync = DateTime.tryParse('${_info['lastSync'] ?? ''}');
    if (!_connected || sync == null) return null;
    return tr.adminPaperBuddyStatus(
      _info['count'] ?? 0,
      DateFormat.yMd(appLanguage).add_jm().format(sync.toLocal()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final engine = AppScope.read(context).engine!;
    final lastError = _info['lastError'] as String?;
    return AlertDialog(
      title: Text(tr.adminPaperBuddy),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tr.adminPaperBuddyIntro,
                      style: TextStyle(color: c.inkSoft),
                    ),
                    if (_status case final status?) ...[
                      const SizedBox(height: 8),
                      Text(
                        status,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                    if (lastError != null && lastError.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        localizeServerText(lastError),
                        style: TextStyle(color: c.danger),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: _url,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: tr.adminPaperBuddyUrl,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _token,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: tr.adminPaperBuddyToken,
                        helperText: _connected
                            ? tr.adminPaperBuddyTokenKept
                            : tr.adminPaperBuddyTokenHint,
                        helperMaxLines: 3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _tag,
                      decoration: InputDecoration(
                        labelText: tr.adminPaperBuddyTag,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(tr.adminPaperBuddyWho),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final m in engine.members)
                          FilterChip(
                            label: Text(m.displayName),
                            selected: _members.contains(m.id),
                            onSelected: (on) => setState(
                              () => on
                                  ? _members.add(m.id)
                                  : _members.remove(m.id),
                            ),
                          ),
                      ],
                    ),
                    if (_error case final error?) ...[
                      const SizedBox(height: 12),
                      Text(error, style: TextStyle(color: c.danger)),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        if (_connected) ...[
          TextButton(
            onPressed: _busy ? null : _remove,
            child: Text(tr.adminPaperBuddyRemove),
          ),
          TextButton(
            onPressed: _busy ? null : () => _run(_api.syncPaperBuddy),
            child: Text(tr.adminPaperBuddySyncNow),
          ),
        ],
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.commonClose),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_connected ? tr.commonSave : tr.adminPaperBuddyConnect),
        ),
      ],
    );
  }
}
