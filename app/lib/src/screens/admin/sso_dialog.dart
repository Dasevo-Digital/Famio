part of '../admin_screens.dart';

/// Admins set up the single sign-on provider.
Future<void> showSsoDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _SsoDialog());

class _SsoDialog extends StatefulWidget {
  const _SsoDialog();

  @override
  State<_SsoDialog> createState() => _SsoDialogState();
}

class _SsoDialogState extends State<_SsoDialog> {
  final _issuer = TextEditingController();
  final _clientId = TextEditingController();
  final _secret = TextEditingController();
  final _label = TextEditingController();
  var _match = false;
  var _configured = false;
  var _secretSet = false;
  String? _redirect;
  String? _error;
  var _loading = true;
  var _busy = false;

  FamioApiClient get _api => AppScope.read(context).engine!.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_issuer, _clientId, _secret, _label]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply(Map<String, Object?> json) {
    _issuer.text = json['issuer'] as String? ?? '';
    _clientId.text = json['clientId'] as String? ?? '';
    _label.text = json['label'] as String? ?? '';
    _match = json['matchUsername'] as bool? ?? false;
    _configured = json['configured'] as bool? ?? false;
    _secretSet = json['secretSet'] as bool? ?? false;
    _redirect = json['redirectUri'] as String?;
  }

  Future<void> _load() async {
    try {
      final json = await _api.ssoConfig();
      if (mounted) setState(() => _apply(json));
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final json = await _api.saveSsoConfig(
        issuer: _issuer.text.trim(),
        clientId: _clientId.text.trim(),
        clientSecret: _secret.text,
        label: _label.text.trim(),
        matchUsername: _match,
      );
      if (!mounted) return;
      setState(() => _apply(json));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.ssoSingleSignSaved)));
      Navigator.pop(context);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    try {
      await _api.deleteSsoConfig();
      if (mounted) Navigator.pop(context);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return AlertDialog(
      title: const Text('Single Sign-On'),
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
                      tr.ssoProviderEGAuthentik,
                      style: TextStyle(color: c.inkSoft),
                    ),
                    const SizedBox(height: 6),
                    if (_redirect case final redirect?)
                      Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              redirect,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: tr.commonCopy,
                            icon: const Icon(AppIcons.copy, size: 18),
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: redirect),
                            ),
                          ),
                        ],
                      )
                    else
                      Text(
                        tr.ssoFirstEnterSavePublic,
                        style: TextStyle(color: c.danger),
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _issuer,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: tr.ssoProviderAddressIssuer,
                        hintText:
                            'https://auth.example.de/application/o/famio/',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _clientId,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Client-ID'),
                    ),
                    const SizedBox(height: 12),
                    PasswordReveal(
                      builder: (_, obscure, toggle) => TextField(
                        controller: _secret,
                        obscureText: obscure,
                        contextMenuBuilder: PasswordReveal.contextMenu,
                        decoration: InputDecoration(
                          labelText: 'Client-Secret',
                          helperText: _secretSet
                              ? tr.ssoSavedLeaveEmptyKeep
                              : null,
                          suffixIcon: toggle,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _label,
                      decoration: InputDecoration(
                        labelText: tr.ssoNameButton,
                        hintText: 'Authentik',
                        helperText: tr.ssoSignSignScreen,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr.ssoMatchIdenticalUsernames),
                      subtitle: Text(tr.ssoWhoeverHasSameUsername),
                      value: _match,
                      onChanged: (v) => setState(() => _match = v),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!, style: TextStyle(color: c.danger)),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        if (_configured)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: c.danger),
            onPressed: _busy ? null : _remove,
            child: Text(tr.commonRemove),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.commonCancel),
        ),
        FilledButton(
          onPressed: _busy || _loading || _redirect == null ? null : _save,
          child: Text(tr.commonSave),
        ),
      ],
    );
  }
}
