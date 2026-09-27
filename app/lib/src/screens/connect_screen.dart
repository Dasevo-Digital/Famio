import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/trust_certificate.dart';
import '../environment.dart';
import '../widgets/password_reveal.dart';

/// Server address, then login – or the admin setup on a fresh server.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _formKey = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _displayName = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _setupCode = TextEditingController();

  ResolvedServer? _resolved;
  ServerInfo? get _server => _resolved?.info;
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final state = AppScope.read(context);
    _url.text = state.serverUrl ?? '';
    _error = state.notice;
  }

  @override
  void dispose() {
    for (final c in [_url, _displayName, _username, _password, _setupCode]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    // The keyboard would cover the certificate dialog on small phones.
    FocusScope.of(context).unfocus();
    final state = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final resolved = _resolved;
      final server = resolved?.info;
      if (resolved == null || server == null) {
        final found = await state.resolveServer(
          _url.text,
          trust: (fingerprint) => confirmCertificate(context, fingerprint),
        );
        setState(() => _resolved = found);
      } else if (server.setupRequired) {
        await state.setupServer(
          resolved,
          displayName: _displayName.text,
          username: _username.text,
          password: _password.text,
          setupCode: server.setupCodeRequired ? _setupCode.text : null,
        );
      } else {
        await state.signIn(resolved, _username.text, _password.text);
      }
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } on FormatException {
      setState(() => _error = 'Ungültige Server-Adresse');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final server = _server;
    final setup = server?.setupRequired ?? false;
    final accent = c.strong(FamioSection.calendar);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              c.tint(FamioSection.home),
              c.tint(FamioSection.kids),
              c.tint(FamioSection.calendar),
            ],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SoftCard(
                padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                child: Form(
                  key: _formKey,
                  child: AutofillGroup(
                    // Test accounts of "Famio Dev" stay out of the phone's
                    // password manager.
                    onDisposeAction: AppEnv.isDev
                        ? AutofillContextAction.cancel
                        : AutofillContextAction.commit,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFFFFB38A), Color(0xFFF26B8F)],
                              ),
                              borderRadius: BorderRadius.circular(26),
                            ),
                            child: Image.asset(
                              'assets/icon/logo_glyph.png',
                              width: 56,
                              height: 56,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          AppEnv.appName,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.displaySmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          server == null
                              ? 'Euer Familien-Organizer'
                              : setup
                              ? 'Neuer Server – lege das erste Konto an.\nEs wird Administrator.'
                              : 'Schön, dass du da bist!',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: c.inkSoft,
                          ),
                        ),
                        const SizedBox(height: 24),
                        TextFormField(
                          controller: _url,
                          enabled: server == null && !_busy,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: 'Server-Adresse',
                            hintText: 'famio.example.de oder 192.168.1.10',
                            prefixIcon: const Icon(AppIcons.hardDrives),
                            suffixIcon: server == null
                                ? null
                                : IconButton(
                                    icon: const Icon(
                                      AppIcons.pencilSimple,
                                      size: 18,
                                    ),
                                    tooltip: 'Server ändern',
                                    onPressed: () =>
                                        setState(() => _resolved = null),
                                  ),
                          ),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'Bitte Adresse eingeben'
                              : null,
                          onFieldSubmitted: (_) => _submit(),
                        ),
                        if (_resolved case final resolved?)
                          _ConnectionHint(resolved),
                        if (setup && server!.setupCodeRequired) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _setupCode,
                            enabled: !_busy,
                            autocorrect: false,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: 'Einrichtungscode',
                              helperText:
                                  'Steht im Server-Log, z. B.: docker logs famio',
                              prefixIcon: Icon(AppIcons.key),
                            ),
                            validator: (v) => (v ?? '').trim().isEmpty
                                ? 'Code aus dem Server-Log eingeben'
                                : null,
                          ),
                        ],
                        if (setup) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _displayName,
                            enabled: !_busy,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              labelText: 'Dein Name',
                              prefixIcon: Icon(AppIcons.smiley),
                            ),
                          ),
                        ],
                        if (server != null) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _username,
                            enabled: !_busy,
                            autocorrect: false,
                            autofillHints: const [AutofillHints.username],
                            decoration: const InputDecoration(
                              labelText: 'Benutzername',
                              prefixIcon: Icon(AppIcons.user),
                            ),
                            validator: (v) => (v ?? '').trim().isEmpty
                                ? 'Bitte Benutzernamen eingeben'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          PasswordReveal(
                            builder: (_, obscure, toggle) => TextFormField(
                              controller: _password,
                              enabled: !_busy,
                              obscureText: obscure,
                              autofillHints: [
                                setup
                                    ? AutofillHints.newPassword
                                    : AutofillHints.password,
                              ],
                              decoration: InputDecoration(
                                suffixIcon: toggle,
                                labelText: 'Passwort',
                                prefixIcon: Icon(AppIcons.lockKey),
                              ),
                              validator: (v) => setup && (v ?? '').length < 8
                                  ? 'Mindestens 8 Zeichen'
                                  : null,
                              onFieldSubmitted: (_) => _submit(),
                            ),
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        _busy
                            ? const Center(child: CircularProgressIndicator())
                            : ColorButton(
                                label: server == null
                                    ? 'Verbinden'
                                    : (setup ? 'Konto anlegen' : 'Anmelden'),
                                color: accent,
                                onPressed: _submit,
                              ),
                        if (server != null && !setup) ...[
                          const SizedBox(height: 16),
                          Text(
                            'Mit Home Assistant? Öffne Famio in der Seitenleiste, '
                            'um ein Passwort für die App festzulegen.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tells how the chosen server connection is protected.
class _ConnectionHint extends StatelessWidget {
  const _ConnectionHint(this.server);

  final ResolvedServer server;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final encrypted =
        FamioApiClient.transportSecurity(Uri.parse(server.url)) ==
        TransportSecurity.encrypted;
    final text = encrypted
        ? (server.pin == null
              ? 'Verschlüsselt verbunden'
              : 'Verschlüsselt verbunden (Zertifikat bestätigt)')
        : 'Unverschlüsselt im Heimnetz – der Server bietet kein HTTPS an';
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 4),
      child: Row(
        children: [
          Icon(
            encrypted ? AppIcons.lock : AppIcons.warningCircle,
            size: 16,
            color: encrypted
                ? c.strong(FamioSection.tasks)
                : c.strong(FamioSection.home),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
