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
import '../l10n.dart';

DateFormat get _until => DateFormat.MMMMEEEEd(appLanguage).add_jm();

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
        : tr.inviteInvitationFamioForname1(
            created.displayName.isEmpty
                ? ''
                : tr.inviteName(created.displayName),
            state.serverUrl,
            created.code,
            _until.format(created.expiresAt),
          );
    return SectionPage(
      section: FamioSection.settings,
      title: tr.inviteInvite,
      subtitle: tr.inviteWithoutPassingPassword,
      maxBodyWidth: 720,
      body: ListView(
        padding: EdgeInsets.only(bottom: listBottomPadding(context)),
        children: [
          if (created == null) ...[
            SoftCard(child: Text(tr.inviteNewMemberChoosesTheir)),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: tr.inviteNameSuggestion,
                hintText: tr.inviteEGGrandmaErika,
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
              label: Text(tr.inviteCreateInvitation),
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
                tr.inviteRoleValidUntilUntil(
                  created.role.label,
                  _until.format(created.expiresAt),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(tr.inviteScanQrCodeFamio),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(AppIcons.copy),
              label: Text(tr.inviteCopyInvitationText),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(tr.inviteCopied)));
              },
            ),
            TextButton(
              onPressed: () => setState(() {
                _created = null;
                _name.clear();
              }),
              child: Text(tr.inviteAnotherInvitation),
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
                  ListHeading(tr.inviteOpenInvitations, color: accent),
                  for (final i in open)
                    ListTile(
                      leading: const Icon(AppIcons.userPlus),
                      title: Text(
                        i.displayName.isEmpty ? i.role.label : i.displayName,
                      ),
                      subtitle: Text(
                        tr.inviteRoleUntilUntil(
                          i.role.label,
                          _until.format(i.expiresAt),
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: tr.inviteWithdraw,
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
            BarcodeScanScreen(qr: true, title: tr.inviteScanInvitation),
      ),
    );
    if (text == null || !mounted) return;
    final link = InviteLink.parse(text);
    if (link == null) {
      setState(() => _error = tr.inviteNotFamioInvitationCode);
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
      setState(() => _error = tr.settingsInvalidServerAddress);
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
      appBar: AppBar(title: Text(tr.inviteJoin)),
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
                      label: Text(tr.inviteScanQrCode),
                      onPressed: _busy ? null : _scan,
                    ),
                    const SizedBox(height: 16),
                    Text(tr.inviteInvitationText),
                    const SizedBox(height: 8),
                  ],
                  TextField(
                    controller: _server,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: tr.settingsServer,
                      hintText: 'z. B. https://famio.example.org',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: tr.commonCode,
                      hintText: 'ABCD-EFGH',
                    ),
                    onSubmitted: (_) => _check(),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _check,
                    child: Text(tr.commonNext),
                  ),
                ] else ...[
                  Text(
                    tr.inviteYouInvitedRole(invite.role.label),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(tr.inviteChooseHowYouWant),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _name,
                    decoration: InputDecoration(labelText: tr.inviteName2),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _username,
                    autocorrect: false,
                    decoration: InputDecoration(labelText: tr.commonUsername),
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
                        labelText: tr.invitePasswordLeast8Characters,
                      ),
                      onSubmitted: (_) => _join(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _join,
                    child: Text(tr.inviteJoin2),
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
