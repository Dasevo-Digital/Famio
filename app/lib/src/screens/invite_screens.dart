import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_state.dart';
import '../data/usernames.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/password_reveal.dart';
import '../widgets/trust_certificate.dart';
import 'pantry_screens.dart' show BarcodeScanScreen;

final _until = DateFormat("EEEE, d. MMMM 'um' HH:mm 'Uhr'", 'de');

/// Admins: invite someone instead of handing over a password. Shows the
/// QR code and a text to send; also lists and withdraws open invitations.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  final _name = TextEditingController();
  var _role = MemberRole.adult;
  InviteInfo? _created;
  late Future<List<InviteInfo>> _open = _load();
  var _busy = false;
  String? _error;

  Future<List<InviteInfo>> _load() =>
      AppScope.read(context).engine!.api.openInvites();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final invite = await AppScope.read(
        context,
      ).engine!.api.createInvite(role: _role, displayName: _name.text.trim());
      setState(() {
        _created = invite;
        _open = _load();
      });
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(InviteInfo invite) async {
    await AppScope.read(context).engine!.api.revokeInvite(invite.id!);
    setState(() {
      if (_created?.id == invite.id) _created = null;
      _open = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final accent = FamioColors.of(context).strong(FamioSection.settings);
    final created = _created;
    final link = created == null
        ? null
        : InviteLink(
            server: state.serverUrl!,
            code: created.code!,
            pin: state.certificatePin,
          );
    final text = created == null
        ? ''
        : 'Einladung zu Famio${created.displayName.isEmpty ? '' : ' für ${created.displayName}'}:\n'
              '1. Famio installieren und öffnen\n'
              '2. „Mit Einladung beitreten“ wählen\n'
              '3. Server: ${state.serverUrl}\n'
              '   Code: ${created.code}\n'
              'Gültig bis ${_until.format(created.expiresAt)}.';
    return SectionPage(
      section: FamioSection.settings,
      title: 'Einladen',
      subtitle: 'Ohne Passwort weiterzugeben',
      maxBodyWidth: 720,
      body: ListView(
        padding: EdgeInsets.only(bottom: listBottomPadding(context)),
        children: [
          if (created == null) ...[
            const SoftCard(
              child: Text(
                'Das neue Mitglied wählt Benutzername und Passwort selbst. '
                'Die Einladung gilt 48 Stunden und nur einmal.',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name (Vorschlag)',
                hintText: 'z. B. Oma Erika',
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<MemberRole>(
              segments: [
                for (final r in [
                  MemberRole.adult,
                  MemberRole.child,
                  MemberRole.guest,
                ])
                  ButtonSegment(value: r, label: Text(r.label)),
              ],
              selected: {_role},
              onSelectionChanged: (s) => setState(() => _role = s.first),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(AppIcons.userPlus),
              label: const Text('Einladung erstellen'),
              onPressed: _busy ? null : _create,
            ),
          ] else ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                color: Colors.white,
                child: QrImageView(
                  data: link!.encode(),
                  size: 240,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: SelectableText(
                created.code!,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                '${created.role.label} · gültig bis '
                '${_until.format(created.expiresAt)}',
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Mit Famio auf dem neuen Gerät den QR-Code scannen – oder den '
              'Text unten schicken.',
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(AppIcons.copy),
              label: const Text('Einladungstext kopieren'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Kopiert')));
              },
            ),
            TextButton(
              onPressed: () => setState(() {
                _created = null;
                _name.clear();
              }),
              child: const Text('Weitere Einladung'),
            ),
          ],
          FutureBuilder<List<InviteInfo>>(
            future: _open,
            builder: (context, snapshot) {
              final open = snapshot.data ?? const [];
              if (open.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListHeading('Offene Einladungen', color: accent),
                  for (final i in open)
                    ListTile(
                      leading: const Icon(AppIcons.userPlus),
                      title: Text(
                        i.displayName.isEmpty ? i.role.label : i.displayName,
                      ),
                      subtitle: Text(
                        '${i.role.label} · bis ${_until.format(i.expiresAt)}',
                      ),
                      trailing: IconButton(
                        tooltip: 'Zurückziehen',
                        icon: const Icon(AppIcons.trash),
                        onPressed: () => _revoke(i),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// A newcomer joins with an invitation: scan the QR code (or type server
/// and code), then choose name, username and password.
class JoinWithInviteScreen extends StatefulWidget {
  const JoinWithInviteScreen({super.key});

  @override
  State<JoinWithInviteScreen> createState() => _JoinWithInviteScreenState();
}

class _JoinWithInviteScreenState extends State<JoinWithInviteScreen> {
  final _server = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  String? _pin;
  ResolvedServer? _resolved;
  InviteInfo? _invite;
  var _busy = false;
  String? _error;

  static bool get _canScan => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void dispose() {
    for (final c in [_server, _code, _name, _username, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _scan() async {
    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            const BarcodeScanScreen(qr: true, title: 'Einladung scannen'),
      ),
    );
    if (text == null || !mounted) return;
    final link = InviteLink.parse(text);
    if (link == null) {
      setState(() => _error = 'Das ist kein Famio-Einladungscode.');
      return;
    }
    _server.text = link.server;
    _code.text = link.code;
    _pin = link.pin;
    await _check();
  }

  /// Connects to the server and looks the code up.
  Future<void> _check() async {
    FocusScope.of(context).unfocus();
    final state = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    String fold(String s) => s.replaceAll(':', '').toUpperCase();
    try {
      final resolved = await state.resolveServer(
        _server.text,
        // From the QR code: the certificate the inviting admin trusts.
        trust: (fingerprint) async =>
            (_pin != null && fold(_pin!) == fold(fingerprint)) ||
            await confirmCertificate(context, fingerprint),
      );
      final invite = await AppState.clientFor(
        resolved,
      ).checkInvite(_code.text.trim());
      final taken = <String>[];
      setState(() {
        _resolved = resolved;
        _invite = invite;
        _name.text = invite.displayName;
        _username.text = suggestUsername(invite.displayName, taken);
      });
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } on FormatException {
      setState(() => _error = 'Ungültige Server-Adresse');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    final state = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.joinWithInvite(
        _resolved!,
        code: _code.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
        displayName: _name.text.trim(),
      );
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final invite = _invite;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Mit Einladung beitreten')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (invite == null) ...[
                  if (_canScan) ...[
                    FilledButton.icon(
                      icon: const Icon(AppIcons.scanBarcode),
                      label: const Text('QR-Code scannen'),
                      onPressed: _busy ? null : _scan,
                    ),
                    const SizedBox(height: 16),
                    const Text('Oder aus dem Einladungstext:'),
                    const SizedBox(height: 8),
                  ],
                  TextField(
                    controller: _server,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Server',
                      hintText: 'z. B. https://famio.example.org',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Code',
                      hintText: 'ABCD-EFGH',
                    ),
                    onSubmitted: (_) => _check(),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _check,
                    child: const Text('Weiter'),
                  ),
                ] else ...[
                  Text(
                    'Du wirst als ${invite.role.label} eingeladen.',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  const Text('Wähle, wie du dich anmelden möchtest.'),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Dein Name'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _username,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Benutzername',
                    ),
                  ),
                  const SizedBox(height: 12),
                  PasswordReveal(
                    builder: (_, obscure, toggle) => TextField(
                      controller: _password,
                      obscureText: obscure,
                      contextMenuBuilder: PasswordReveal.contextMenu,
                      autofillHints: const [AutofillHints.newPassword],
                      decoration: InputDecoration(
                        suffixIcon: toggle,
                        labelText: 'Passwort (mindestens 8 Zeichen)',
                      ),
                      onSubmitted: (_) => _join(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _join,
                    child: const Text('Beitreten'),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
