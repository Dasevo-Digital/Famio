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

/// Asks for the code of the authenticator app – or a recovery code.
/// Returns null if cancelled. [error] is shown above the field (e.g. after
/// a wrong code).
Future<String?> askTwoFactorCode(
  BuildContext context, {
  String title = 'Bestätigungscode',
  String? error,
}) => showDialog<String>(
  context: context,
  builder: (context) => _CodeDialog(title: title, error: error),
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
                  ? 'Einen deiner Wiederherstellungscodes eingeben. Jeder Code '
                        'funktioniert nur einmal.'
                  : 'Den 6-stelligen Code aus deiner Authenticator-App '
                        'eingeben.',
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
                labelText: _recovery ? 'Wiederherstellungscode' : 'Code',
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
                      ? 'Code aus der App verwenden'
                      : 'Handy nicht zur Hand? Wiederherstellungscode',
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Bestätigen')),
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
      title: Text('Anmelden mit $label'),
      content: const Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Text(
              'Die Anmeldung läuft im Browser. Danach geht es hier '
              'automatisch weiter.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
            Navigator.pop(context);
          },
          child: const Text('Abbrechen'),
        ),
      ],
    ),
  );
  final navigator = Navigator.of(context);
  try {
    await run((url) async {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw const ApiError(0, 'browser', 'Browser ließ sich nicht öffnen');
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
        Text(
          'Falls dein Handy verloren geht, kommst du mit einem dieser Codes '
          'trotzdem hinein – jeder funktioniert einmal. Jetzt sicher '
          'aufbewahren (Passwortmanager oder ausgedruckt). Sie werden nur '
          'dieses eine Mal angezeigt.',
          style: TextStyle(color: c.inkSoft),
        ),
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
            label: const Text('Kopieren'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: codes.join('\n')));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Codes kopiert')));
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
      title: 'Zwei-Faktor einrichten',
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
                'Zwei-Faktor ist eingeschaltet',
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
              label: 'Codes gesichert – fertig',
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
        Text(
          '1. Den QR-Code mit einer Authenticator-App scannen (z. B. '
          '2FAS, Aegis, Google Authenticator, Microsoft Authenticator oder '
          'dem Passwortmanager).',
          style: TextStyle(color: c.inkSoft),
        ),
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
        Text(
          'Oder den Schlüssel von Hand eingeben:',
          style: TextStyle(color: c.inkSoft),
        ),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                grouped,
                style: const TextStyle(fontSize: 16, letterSpacing: 1.5),
              ),
            ),
            IconButton(
              tooltip: 'Schlüssel kopieren',
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
            label: const Text('In Authenticator-App auf diesem Gerät öffnen'),
            onPressed: () => launchUrl(Uri.parse(setup.uri)),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '2. Den Code eingeben, den die App jetzt anzeigt:',
          style: TextStyle(color: c.inkSoft),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          maxLength: 6,
          decoration: const InputDecoration(
            labelText: 'Code',
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
            label: 'Einschalten',
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
        title: const Text('Zwei-Faktor ausschalten?'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Danach reicht wieder das Passwort allein. Zur Sicherheit '
                'Passwort und aktuellen Code eingeben.',
              ),
              const SizedBox(height: 12),
              PasswordReveal(
                builder: (_, obscure, toggle) => TextField(
                  controller: password,
                  obscureText: obscure,
                  contextMenuBuilder: PasswordReveal.contextMenu,
                  decoration: InputDecoration(
                    labelText: 'Passwort',
                    suffixIcon: toggle,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: code,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Code oder Wiederherstellungscode',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: FamioColors.of(context).danger,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ausschalten'),
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
      _say('Zwei-Faktor ausgeschaltet');
    } on ApiError catch (e) {
      _say(e.message);
    }
    if (mounted) _reload();
  }

  Future<void> _newCodes() async {
    final code = await askTwoFactorCode(context, title: 'Neue Codes');
    if (code == null || !mounted) return;
    try {
      final codes = await _api.newRecoveryCodes(code);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Neue Wiederherstellungscodes'),
          content: SizedBox(width: 380, child: RecoveryCodes(codes)),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Gesichert'),
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
      _say('Verknüpfung gelöst');
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
      title: 'Anmeldung & Sicherheit',
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
              ListHeading('Zwei-Faktor-Anmeldung', color: accent),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  status.enabled ? AppIcons.shieldCheck : AppIcons.shield,
                  color: status.enabled ? c.strong(FamioSection.tasks) : null,
                ),
                title: Text(status.enabled ? 'Eingeschaltet' : 'Aus'),
                subtitle: Text(
                  status.enabled
                      ? 'Beim Anmelden fragt Famio zusätzlich nach dem Code '
                            'aus deiner Authenticator-App. Noch '
                            '${status.recoveryCodesLeft} Wiederherstellungs'
                            'codes übrig.'
                      : 'Schützt dein Konto, falls jemand dein Passwort '
                            'kennt: Beim Anmelden braucht es zusätzlich einen '
                            'Code aus einer Authenticator-App.'
                            '${status.required ? ' Für dein Konto Pflicht.' : ''}',
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: status.enabled
                    ? [
                        OutlinedButton.icon(
                          icon: const Icon(AppIcons.key, size: 18),
                          label: const Text('Neue Wiederherstellungscodes'),
                          onPressed: _newCodes,
                        ),
                        if (!status.required)
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: c.danger,
                            ),
                            icon: const Icon(AppIcons.trash, size: 18),
                            label: const Text('Ausschalten'),
                            onPressed: _disable,
                          ),
                      ]
                    : [
                        ColorButton(
                          label: 'Einrichten',
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
                        ? 'Verknüpft'
                              '${status.singleSignOnName == null ? '' : ' mit ${status.singleSignOnName}'}'
                        : 'Nicht verknüpft',
                  ),
                  subtitle: Text(
                    'Anmelden mit ${status.singleSignOnLabel ?? 'dem Anbieter'} '
                    'statt Passwort – auf dem Anmeldebildschirm. Die '
                    'Zwei-Faktor-Prüfung übernimmt dann der Anbieter.',
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
                              ? 'Neu verknüpfen'
                              : 'Mit $label verknüpfen',
                        ),
                        onPressed: () => _link(label),
                      ),
                    if (status.singleSignOn)
                      OutlinedButton.icon(
                        icon: const Icon(AppIcons.unlink, size: 18),
                        label: const Text('Verknüpfung lösen'),
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
      title: 'Zwei-Faktor-Anmeldung',
      subtitle: 'Für dein Konto Pflicht',
      maxBodyWidth: 560,
      actions: [
        BubbleButton(
          icon: AppIcons.signOut,
          tooltip: 'Abmelden',
          onPressed: () => state.signOut(),
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          Text(
            'Ein Administrator hat die Zwei-Faktor-Anmeldung für dein Konto '
            'eingeschaltet. ${gate?.verifyNeeded ?? false ? 'Bitte auf diesem Gerät einmal mit dem Code aus deiner Authenticator-App bestätigen.' : 'Richte sie jetzt ein – danach geht es gleich weiter.'}',
          ),
          const SizedBox(height: 16),
          if (gate?.verifyNeeded ?? false) ...[
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.visiblePassword,
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: const InputDecoration(
                labelText: 'Code oder Wiederherstellungscode',
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
                label: 'Bestätigen',
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
