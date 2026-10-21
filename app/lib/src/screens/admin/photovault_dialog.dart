part of '../admin_screens.dart';

/// Admins connect the family's PhotoVault: memories and the wall display's
/// album from there, photos of the family chat as contributions to a share
/// link, birthdays from the family tree (see `PhotoVaultLink`).
Future<void> showPhotoVaultDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _PhotoVaultDialog(),
);

class _PhotoVaultDialog extends StatefulWidget {
  const _PhotoVaultDialog();

  @override
  State<_PhotoVaultDialog> createState() => _PhotoVaultDialogState();
}

class _PhotoVaultDialogState extends State<_PhotoVaultDialog> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _share = TextEditingController();
  final _sharePassword = TextEditingController();
  final _members = <String>{};
  var _memories = true;
  var _birthdays = false;
  String? _album;

  /// Random photos of the whole timeline instead of an album.
  var _timeline = false;
  static const _timelineChoice = '\u0000timeline';
  List<Map<String, Object?>> _albums = const [];

  /// PhotoVault asked for a code: the second step of signing in.
  String? _vorgang;
  Map<String, Object?> _info = const {};
  String? _error;
  var _loading = true;
  var _busy = false;

  FamioApiClient get _api => AppScope.read(context).engine!.api;
  bool get _connected => _info['connected'] == true;

  @override
  void initState() {
    super.initState();
    _run(_api.photoVault, loading: true);
  }

  @override
  void dispose() {
    for (final c in [_url, _name, _password, _code, _share, _sharePassword]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply(Map<String, Object?> json) {
    if (json['step'] == 'totp') {
      _vorgang = json['vorgang'] as String?;
      return;
    }
    _info = json;
    _vorgang = null;
    _password.clear();
    _code.clear();
    if (!_connected) return;
    _url.text = json['url'] as String? ?? '';
    _memories = json['memories'] as bool? ?? true;
    _birthdays = json['birthdays'] as bool? ?? false;
    _album = json['albumId'] as String?;
    _timeline = json['timeline'] as bool? ?? false;
    _share.text = json['shareUrl'] as String? ?? '';
    _sharePassword.clear();
    _members
      ..clear()
      ..addAll([for (final m in json['memberIds'] as List? ?? const []) '$m']);
    unawaited(_loadAlbums());
  }

  Future<void> _loadAlbums() async {
    try {
      final albums = await _api.photoVaultAlbums();
      if (mounted) setState(() => _albums = albums);
    } on ApiError {
      // The status line shows what PhotoVault said.
    }
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

  Future<void> _connect() => _run(
    () => _vorgang == null
        ? _api.connectPhotoVault(
            url: _url.text.trim(),
            name: _name.text.trim(),
            password: _password.text,
          )
        : _api.connectPhotoVault(
            url: _url.text.trim(),
            vorgang: _vorgang,
            code: _code.text.trim(),
          ),
  );

  Future<void> _save() async {
    final ok = await _run(
      () => _api.savePhotoVault({
        'memories': _memories,
        'albumId': _album ?? '',
        'timeline': _timeline,
        'shareUrl': _share.text.trim(),
        if (_sharePassword.text.isNotEmpty)
          'sharePassword': _sharePassword.text,
        'birthdays': _birthdays,
        'memberIds': _members.toList(),
      }),
    );
    if (ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.adminPhotoVaultSaved)));
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr.adminPhotoVaultRemove),
        content: Text(tr.adminPhotoVaultRemoveText),
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
    if (ok == true && mounted) await _run(_api.deletePhotoVault);
  }

  String? get _status {
    final sync = DateTime.tryParse('${_info['lastSync'] ?? ''}');
    if (!_connected || sync == null) return null;
    int n(String key) => (_info[key] as num?)?.toInt() ?? 0;
    return tr.adminPhotoVaultStatus(
      DateFormat.yMd(appLanguage).add_jm().format(sync.toLocal()),
      n('memoryCount'),
      n('albumCount'),
      n('birthdayCount'),
      n('sentTotal'),
    );
  }

  List<Widget> _signIn() => [
    TextField(
      controller: _url,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enabled: _vorgang == null,
      decoration: InputDecoration(
        labelText: tr.adminPhotoVaultUrl,
        hintText: 'https://photos.example.de',
      ),
    ),
    const SizedBox(height: 8),
    if (_vorgang == null) ...[
      TextField(
        controller: _name,
        autocorrect: false,
        decoration: InputDecoration(labelText: tr.adminPhotoVaultName),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _password,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(labelText: tr.adminPhotoVaultPassword),
        onSubmitted: (_) => _connect(),
      ),
    ] else
      TextField(
        controller: _code,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: tr.adminPhotoVaultCode),
        onSubmitted: (_) => _connect(),
      ),
  ];

  List<Widget> _options(SyncEngine engine) {
    final skipped = [
      for (final s in _info['skippedBirthdays'] as List? ?? const [])
        if (s is Map) '${s['name']} (${s['birthday']}): ${s['reason']}',
    ];
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _memories,
        onChanged: (v) => setState(() => _memories = v),
        title: Text(tr.adminPhotoVaultMemories),
      ),
      DropdownButtonFormField<String?>(
        initialValue: _timeline
            ? _timelineChoice
            : _albums.any((a) => a['id'] == _album)
            ? _album
            : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: tr.adminPhotoVaultAlbum),
        items: [
          DropdownMenuItem(value: null, child: Text(tr.adminPhotoVaultNoAlbum)),
          DropdownMenuItem(
            value: _timelineChoice,
            child: Text(
              tr.adminPhotoVaultTimeline,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          for (final a in _albums)
            DropdownMenuItem(
              value: '${a['id']}',
              child: Text(
                '${a['name']} (${a['count'] ?? 0})',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) => setState(() {
          _timeline = v == _timelineChoice;
          _album = _timeline ? null : v;
        }),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _share,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: tr.adminPhotoVaultShare,
          hintText: 'https://photos.example.de/teilen/…',
          helperText: tr.adminPhotoVaultShareHint,
          helperMaxLines: 4,
        ),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _sharePassword,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: tr.adminPhotoVaultSharePassword,
          helperText: _info['sharePassword'] == true
              ? tr.adminPaperBuddyTokenKept
              : null,
        ),
      ),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _birthdays,
        onChanged: (v) => setState(() => _birthdays = v),
        title: Text(tr.adminPhotoVaultBirthdays),
        subtitle: Text(tr.adminPhotoVaultBirthdaysHint),
      ),
      if (_birthdays && skipped.isNotEmpty) ...[
        Text(tr.adminPhotoVaultSkipped),
        for (final s in skipped)
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 2),
            child: Text('• $s', style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
      const SizedBox(height: 12),
      Text(tr.adminPhotoVaultWho),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final m in engine.allMembers)
            if (!m.isGuest)
              FilterChip(
                label: Text(m.displayName),
                selected: _members.contains(m.id),
                onSelected: (on) => setState(
                  () => on ? _members.add(m.id) : _members.remove(m.id),
                ),
              ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final engine = AppScope.read(context).engine!;
    final lastError = _info['lastError'] as String?;
    return AlertDialog(
      title: Text(tr.adminPhotoVault),
      content: SizedBox(
        width: 520,
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
                      tr.adminPhotoVaultIntro,
                      style: TextStyle(color: c.inkSoft),
                    ),
                    if (_connected) ...[
                      const SizedBox(height: 8),
                      Text(
                        tr.adminPhotoVaultConnected(
                          '${_info['account'] ?? ''}',
                          Uri.tryParse('${_info['url'] ?? ''}')?.host ?? '',
                        ),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                    if (_status case final status?) ...[
                      const SizedBox(height: 4),
                      Text(status),
                    ],
                    if (lastError != null && lastError.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        localizeServerText(lastError),
                        style: TextStyle(color: c.danger),
                      ),
                    ],
                    const SizedBox(height: 12),
                    ...(_connected && _vorgang == null
                        ? _options(engine)
                        : _signIn()),
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
            child: Text(tr.adminPhotoVaultRemove),
          ),
          TextButton(
            onPressed: _busy ? null : () => _run(_api.syncPhotoVault),
            child: Text(tr.adminPhotoVaultSyncNow),
          ),
        ],
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.commonClose),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : _connected && _vorgang == null
              ? _save
              : _connect,
          child: Text(
            _connected && _vorgang == null
                ? tr.commonSave
                : _vorgang != null
                ? tr.adminPhotoVaultConfirm
                : tr.adminPhotoVaultConnect,
          ),
        ),
      ],
    );
  }
}
