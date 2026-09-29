import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'design/theme.dart';
import 'screens/security_screens.dart';
import 'screens/connect_screen.dart';
import 'screens/home_shell.dart';
import 'environment.dart';

class FamioApp extends StatelessWidget {
  const FamioApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ValueListenableBuilder(
        valueListenable: state.highContrast,
        builder: (context, highContrast, _) => MaterialApp(
          title: AppEnv.appName,
          debugShowCheckedModeBanner: false,
          theme: famioTheme(Brightness.light, highContrast: highContrast),
          darkTheme: famioTheme(Brightness.dark, highContrast: highContrast),
          // "Kontrast erhöhen" in the system settings (iOS, macOS) as well.
          highContrastTheme: famioTheme(Brightness.light, highContrast: true),
          highContrastDarkTheme: famioTheme(
            Brightness.dark,
            highContrast: true,
          ),
          scrollBehavior: const FamioScrollBehavior(),
          locale: const Locale('de'),
          supportedLocales: const [Locale('de')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          // The development build says so on every screen.
          builder: AppEnv.isDev
              ? (context, child) => Banner(
                  message: 'DEV',
                  location: BannerLocation.topEnd,
                  color: const Color(0xFFE8703A),
                  child: child!,
                )
              : null,
          home: const _Root(),
        ),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: state.insecureVaultConsentRequired
          ? const _InsecureVaultConsent(key: ValueKey('vault-consent'))
          : !state.signedIn
          ? const ConnectScreen(key: ValueKey('connect'))
          : state.twoFactorGate != null
          // An admin made two-factor login mandatory: nothing else first.
          ? const TwoFactorGateScreen(key: ValueKey('two-factor'))
          : const HomeShell(key: ValueKey('home')),
    );
  }
}

class _InsecureVaultConsent extends StatefulWidget {
  const _InsecureVaultConsent({super.key});

  @override
  State<_InsecureVaultConsent> createState() => _InsecureVaultConsentState();
}

class _InsecureVaultConsentState extends State<_InsecureVaultConsent> {
  var _busy = false;
  String? _error;

  Future<void> _continue() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).allowInsecureVault();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_amber_rounded, size: 56),
                const SizedBox(height: 20),
                Text(
                  'Kein System-Schlüsselbund verfügbar',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Famio kann Anmeldung und lokalen Datenbankschlüssel auf '
                  'diesem System nicht geschützt speichern. Wenn du '
                  'fortfährst, liegen diese Geheimnisse lesbar in den '
                  'Anwendungseinstellungen. Richte möglichst zuerst KWallet '
                  'oder den GNOME-Schlüsselbund ein und starte Famio neu.',
                  textAlign: TextAlign.center,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _continue,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Ungeschützte Speicherung erlauben'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
