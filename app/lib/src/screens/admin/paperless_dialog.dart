part of '../admin_screens.dart';

/// Admins connect the family's Paperless-ngx: documents with a tag appear
/// under Documents, read-only, with the date of a chosen field as expiry.
Future<void> showPaperlessDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _PaperlessDialog(),
);

class _PaperlessDialog extends StatefulWidget {
  const _PaperlessDialog();

  @override
  State<_PaperlessDialog> createState() => _PaperlessDialogState();
}

class _PaperlessDialogState extends State<_PaperlessDialog> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  final _tag = TextEditingController(text: 'Familie');
  final _dueField = TextEditingController();
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
    _run(_api.paperless, loading: true);
  }

  @override
  void dispose() {
    for (final c in [_url, _token, _tag, _dueField]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply(Map<String, Object?> json) {
    _info = json;
    if (json['connected'] != true) return;
    _url.text = json['url'] as String? ?? '';
    _tag.text = json['tag'] as String? ?? 'Familie';
    _dueField.text = json['dueField'] as String? ?? '';
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
      () => _api.savePaperless(
        url: _url.text.trim(),
        token: _token.text.trim(),
        tag: _tag.text.trim(),
        memberIds: _members.toList(),
        dueField: _dueField.text.trim(),
      ),
    );
    if (ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.adminPaperlessSaved)));
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr.adminPaperlessRemove),
        content: Text(tr.adminPaperlessRemoveText),
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
    if (ok == true && mounted) await _run(_api.deletePaperless);
  }

  String? get _status {
    final sync = DateTime.tryParse('${_info['lastSync'] ?? ''}');
    if (!_connected || sync == null) return null;
    return tr.adminPaperlessStatus(
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
      title: Text(tr.adminPaperless),
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
                      tr.adminPaperlessIntro,
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
                        labelText: tr.adminPaperlessUrl,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _token,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: tr.adminPaperlessToken,
                        helperText: _connected
                            ? tr.adminTokenKept
                            : tr.adminPaperlessTokenHint,
                        helperMaxLines: 3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _tag,
                      decoration: InputDecoration(
                        labelText: tr.adminPaperlessTag,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _dueField,
                      decoration: InputDecoration(
                        labelText: tr.adminPaperlessDueField,
                        helperText: tr.adminPaperlessDueFieldHint,
                        helperMaxLines: 2,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(tr.adminPaperlessWho),
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
            child: Text(tr.adminPaperlessRemove),
          ),
          TextButton(
            onPressed: _busy ? null : () => _run(_api.syncPaperless),
            child: Text(tr.adminPaperlessSyncNow),
          ),
        ],
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.commonClose),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_connected ? tr.commonSave : tr.adminPaperlessConnect),
        ),
      ],
    );
  }
}
