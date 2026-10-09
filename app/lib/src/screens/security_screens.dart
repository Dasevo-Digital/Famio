import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/password_reveal.dart';
import '../l10n.dart';

/// Asks for the code of the authenticator app – or a recovery code.
/// Returns null if cancelled. [error] is shown above the field (e.g. after
/// a wrong code).
Future<String?> askTwoFactorCode(
  BuildContext context, {
  String? title,
  String? error,
}) => showDialog<String>(
  context: context,
  builder: (context) =>
      _CodeDialog(title: title ?? tr.securityConfirmationCode, error: error),
);

class _CodeDialog extends StatefulWidget {
  const _CodeDialog({required this.title, this.error});

  final String title;
  final String? error;

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  final _code = TextEditingController();
  var _recovery = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _code.text.trim();
    if (code.isNotEmpty) Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _recovery
                  ? tr.securityEnterOneRecoveryCodes
                  : tr.securityEnter6DigitCode,
              style: TextStyle(color: c.inkSoft),
            ),
            if (widget.error != null) ...[
              const SizedBox(height: 8),
              Text(widget.error!, style: TextStyle(color: c.danger)),
            ],
            const SizedBox(height: 12),
            TextField(
              key: ValueKey(_recovery),
              controller: _code,
              autofocus: true,
              autocorrect: false,
              keyboardType: _recovery
                  ? TextInputType.visiblePassword
                  : TextInputType.number,
              autofillHints: _recovery
                  ? null
                  : const [AutofillHints.oneTimeCode],
              maxLength: _recovery ? 12 : 6,
              decoration: InputDecoration(
                labelText: _recovery ? tr.securityRecoveryCode : tr.commonCode,
                hintText: _recovery ? 'abcde-12345' : '123456',
                prefixIcon: const Icon(AppIcons.key),
                counterText: '',
              ),
              onSubmitted: (_) => _submit(),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() {
                  _recovery = !_recovery;
                  _code.clear();
                }),
                child: Text(
                  _recovery
                      ? tr.securityUseCodeApp
                      : tr.securityPhoneNotHandRecovery,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.commonCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(tr.commonConfirm)),
      ],
    );
  }
}

/// Opens the provider's sign-in page in the browser and shows a waiting
/// dialog until [run] finishes (or the user cancels).
Future<void> runSsoInBrowser(
  BuildContext context, {
  required String label,
  required Future<void> Function(
    Future<void> Function(Uri url) open,
    bool Function() cancelled,
  )
  run,
}) async {
  var cancelled = false;
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(tr.commonSignInWith(label)),
      content: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(width: 16),
          Expanded(child: Text(tr.securitySigningHappensBrowserAfterwards)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
            Navigator.pop(context);
          },
          child: Text(tr.commonCancel),
        ),
      ],
    ),
  );
  final navigator = Navigator.of(context);
  try {
    await run((url) async {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw ApiError(0, 'browser', tr.commonBrowserFailed);
      }
    }, () => cancelled);
  } finally {
    if (!cancelled) {
      cancelled = true;
      navigator.pop();
    }
    await dialog;
  }
}

/// Recovery codes, shown once after setting up two-factor login.
class RecoveryCodes extends StatelessWidget {
  const RecoveryCodes(this.codes, {super.key});

  final List<String> codes;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(tr.securityIfYouLosePhone, style: TextStyle(color: c.inkSoft)),
        const SizedBox(height: 12),
        SoftCard(
          child: SelectableText(
            codes.join('\n'),
            style: const TextStyle(letterSpacing: 1, fontSize: 16, height: 1.6),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(AppIcons.copy, size: 18),
            label: Text(tr.commonCopy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: codes.join('\n')));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(tr.securityCodesCopied)));
              }
            },
          ),
        ),
      ],
    );
  }
}

/// Sets up two-factor login: QR code for the authenticator app, a code to
/// confirm it, then the recovery codes. Pops true when done.
class TotpSetupScreen extends StatefulWidget {
  const TotpSetupScreen({super.key, this.embedded = false});

  /// Part of the mandatory-setup screen instead of an own page.
  final bool embedded;

  @override
  State<TotpSetupScreen> createState() => _TotpSetupScreenState();
}

class _TotpSetupScreenState extends State<TotpSetupScreen> {
  final _code = TextEditingController();
  ({String secret, String uri})? _setup;
  List<String>? _recovery;
  String? _error;
  var _busy = false;

  FamioApiClient get _api => AppScope.read(context).engine!.api;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    try {
      final setup = await _api.beginTotp();
      if (mounted) setState(() => _setup = setup);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final codes = await _api.confirmTotp(_code.text.trim());
      if (mounted) setState(() => _recovery = codes);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _done() async {
    final state = AppScope.read(context);
    final navigator = Navigator.of(context);
    await state.refreshTwoFactor();
    if (!widget.embedded && navigator.canPop()) navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final body = _content(context);
    if (widget.embedded) return body;
    return SectionPage(
      section: FamioSection.settings,
      title: tr.securitySetUpTwoFactor,
      maxBodyWidth: 560,
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [body],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.settings);
    final setup = _setup;
    final recovery = _recovery;
    if (recovery != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(AppIcons.shieldCheck, color: c.strong(FamioSection.tasks)),
              const SizedBox(width: 8),
              Text(
                tr.securityTwoFactor,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          RecoveryCodes(recovery),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: ColorButton(
              label: tr.securityCodesSavedDone,
              icon: AppIcons.check,
              color: accent,
              onPressed: _done,
            ),
          ),
        ],
      );
    }
    if (setup == null) {
      return _error == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              ),
            )
          : Text(_error!, style: TextStyle(color: c.danger));
    }
    final grouped = RegExp(
      '.{1,4}',
    ).allMatches(setup.secret).map((m) => m.group(0)).join(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(tr.security1ScanQrCode, style: TextStyle(color: c.inkSoft)),
        const SizedBox(height: 16),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(data: setup.uri, size: 200),
          ),
        ),
        const SizedBox(height: 12),
        Text(tr.securityEnterKeyHand, style: TextStyle(color: c.inkSoft)),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                grouped,
                style: const TextStyle(fontSize: 16, letterSpacing: 1.5),
              ),
            ),
            IconButton(
              tooltip: tr.securityCopyKey,
              icon: const Icon(AppIcons.copy, size: 18),
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: setup.secret)),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(AppIcons.link, size: 18),
            label: Text(tr.securityOpenAuthenticatorAppDevice),
            onPressed: () => launchUrl(Uri.parse(setup.uri)),
          ),
        ),
        const SizedBox(height: 16),
        Text(tr.security2EnterCodeApp, style: TextStyle(color: c.inkSoft)),
        const SizedBox(height: 8),
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          maxLength: 6,
          decoration: InputDecoration(
            labelText: tr.commonCode,
            hintText: '123456',
            prefixIcon: Icon(AppIcons.key),
            counterText: '',
          ),
          onSubmitted: (_) => _confirm(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: c.danger)),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: ColorButton(
            label: tr.commonTurnOn,
            icon: AppIcons.shieldCheck,
            color: accent,
            onPressed: _busy ? null : _confirm,
          ),
        ),
      ],
    );
  }
}

/// Einstellungen → Anmeldung & Sicherheit: two-factor login and the link
/// to the single sign-on provider.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  late Future<TwoFactorStatus> _status;

  FamioApiClient get _api => AppScope.read(context).engine!.api;

  @override
  void initState() {
    super.initState();
    _status = _api.twoFactorStatus();
  }

  void _reload() {
    final status = _api.twoFactorStatus();
    setState(() {
      _status = status;
    });
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _setUp() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<bool>(builder: (_) => const TotpSetupScreen()));
    if (mounted) _reload();
  }

  Future<void> _disable() async {
    final password = TextEditingController();
    final code = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.securityTurnOffTwoFactor),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr.securityAfterThatPasswordAlone),
              const SizedBox(height: 12),
              PasswordReveal(
                builder: (_, obscure, toggle) => TextField(
                  controller: password,
                  obscureText: obscure,
                  contextMenuBuilder: PasswordReveal.contextMenu,
                  decoration: InputDecoration(
                    labelText: tr.commonPassword,
                    suffixIcon: toggle,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: code,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: tr.securityCodeOrRecoveryCode,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: FamioColors.of(context).danger,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.commonTurnOff),
          ),
        ],
      ),
    );
    final input = (password: password.text, code: code.text.trim());
    password.dispose();
    code.dispose();
    if (ok != true) return;
    try {
      await _api.disableTotp(password: input.password, code: input.code);
      _say(tr.securityTwoFactorTurnedOff);
    } on ApiError catch (e) {
      _say(e.message);
    }
    if (mounted) _reload();
  }

  Future<void> _newCodes() async {
    final code = await askTwoFactorCode(context, title: tr.securityNewCodes);
    if (code == null || !mounted) return;
    try {
      final codes = await _api.newRecoveryCodes(code);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr.securityNewRecoveryCodes),
          content: SizedBox(width: 380, child: RecoveryCodes(codes)),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr.securitySaved),
            ),
          ],
        ),
      );
    } on ApiError catch (e) {
      _say(e.message);
    }
    if (mounted) _reload();
  }

  Future<void> _link(String label) async {
    final api = _api;
    try {
      await runSsoInBrowser(
        context,
        label: label,
        run: (open, cancelled) async {
          final flow = await api.startSso(link: true);
          await open(flow.url);
          final end = DateTime.now().add(const Duration(minutes: 10));
          while (!cancelled() && DateTime.now().isBefore(end)) {
            await Future<void>.delayed(const Duration(seconds: 2));
            if (cancelled()) return;
            if (await api.pollSso(flow) != null) return;
          }
        },
      );
    } on ApiError catch (e) {
      _say(e.message);
    }
    if (mounted) _reload();
  }

  Future<void> _unlink() async {
    try {
      await _api.unlinkSso();
      _say(tr.adminLinkRemoved);
    } on ApiError catch (e) {
      _say(e.message);
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.settings);
    return SectionPage(
      section: FamioSection.settings,
      title: tr.settingsSecurity,
      maxBodyWidth: 760,
      body: FutureBuilder(
        future: _status,
        builder: (context, snapshot) {
          final status = snapshot.data;
          if (snapshot.hasError) {
            return Center(child: Text('${snapshot.error}'));
          }
          if (status == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: EdgeInsets.only(
              top: 8,
              bottom: listBottomPadding(context),
            ),
            children: [
              ListHeading(tr.securityTwoFactorSignIn, color: accent),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  status.enabled ? AppIcons.shieldCheck : AppIcons.shield,
                  color: status.enabled ? c.strong(FamioSection.tasks) : null,
                ),
                title: Text(status.enabled ? tr.securityOn : tr.securityOff),
                subtitle: Text(
                  status.enabled
                      ? tr.securityWhenSigningFamioAlso(
                          status.recoveryCodesLeft,
                        )
                      : tr.securityProtectsAccountIfSomeone(
                          status.required ? tr.securityRequiredAccount : '',
                        ),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: status.enabled
                    ? [
                        OutlinedButton.icon(
                          icon: const Icon(AppIcons.key, size: 18),
                          label: Text(tr.securityNewRecoveryCodes),
                          onPressed: _newCodes,
                        ),
                        if (!status.required)
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: c.danger,
                            ),
                            icon: const Icon(AppIcons.trash, size: 18),
                            label: Text(tr.commonTurnOff),
                            onPressed: _disable,
                          ),
                      ]
                    : [
                        ColorButton(
                          label: tr.commonSetUp,
                          icon: AppIcons.qrCode,
                          color: accent,
                          onPressed: _setUp,
                        ),
                      ],
              ),
              if (status.singleSignOnLabel != null || status.singleSignOn) ...[
                ListHeading('Single Sign-On', color: accent),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(AppIcons.logIn),
                  title: Text(
                    status.singleSignOn
                        ? tr.securityLinked(
                            status.singleSignOnName == null
                                ? ''
                                : tr.securityName(status.singleSignOnName!),
                          )
                        : tr.securityNotLinked,
                  ),
                  subtitle: Text(
                    tr.securitySignProviderInsteadPassword(
                      status.singleSignOnLabel ?? tr.securityProvider,
                    ),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    if (status.singleSignOnLabel case final label?)
                      OutlinedButton.icon(
                        icon: const Icon(AppIcons.link, size: 18),
                        label: Text(
                          status.singleSignOn
                              ? tr.securityLinkAgain
                              : tr.securityLinkProvider(label),
                        ),
                        onPressed: () => _link(label),
                      ),
                    if (status.singleSignOn)
                      OutlinedButton.icon(
                        icon: const Icon(AppIcons.unlink, size: 18),
                        label: Text(tr.securityRemoveLink),
                        onPressed: _unlink,
                      ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Shown instead of the app while an admin requires two-factor login and
/// this device has not set it up / confirmed a code yet.
class TwoFactorGateScreen extends StatefulWidget {
  const TwoFactorGateScreen({super.key});

  @override
  State<TwoFactorGateScreen> createState() => _TwoFactorGateScreenState();
}

class _TwoFactorGateScreenState extends State<TwoFactorGateScreen> {
  final _code = TextEditingController();
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final state = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.engine!.api.verifyTwoFactor(_code.text.trim());
      await state.refreshTwoFactor();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final gate = state.twoFactorGate;
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.settings);
    return SectionPage(
      section: FamioSection.settings,
      title: tr.securityTwoFactorSignIn,
      subtitle: tr.securityRequiredAccount2,
      maxBodyWidth: 560,
      actions: [
        BubbleButton(
          icon: AppIcons.signOut,
          tooltip: tr.settingsSignOut,
          onPressed: () => state.signOut(),
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          Text(
            tr.securityAdministratorTurnedTwoFactor(
              gate?.verifyNeeded ?? false
                  ? tr.securityPleaseConfirmOnceDevice
                  : tr.securitySetUpNowThen,
            ),
          ),
          const SizedBox(height: 16),
          if (gate?.verifyNeeded ?? false) ...[
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.visiblePassword,
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: InputDecoration(
                labelText: tr.securityCodeOrRecoveryCode,
                prefixIcon: Icon(AppIcons.key),
              ),
              onSubmitted: (_) => _verify(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: c.danger)),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: ColorButton(
                label: tr.commonConfirm,
                icon: AppIcons.check,
                color: accent,
                onPressed: _busy ? null : _verify,
              ),
            ),
          ] else
            const TotpSetupScreen(embedded: true),
        ],
      ),
    );
  }
}
