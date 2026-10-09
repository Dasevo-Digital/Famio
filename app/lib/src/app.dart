import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'design/theme.dart';
import 'screens/security_screens.dart';
import 'screens/connect_screen.dart';
import 'screens/home_shell.dart';
import 'environment.dart';
import 'l10n.dart';

class FamioApp extends StatelessWidget {
  const FamioApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ListenableBuilder(
        listenable: Listenable.merge([state.highContrast, state.language]),
        builder: (context, _) => MaterialApp(
          // A new language rebuilds everything, also the texts of widgets
          // that would otherwise stay as they are.
          key: ValueKey(appLanguage),
          title: AppEnv.appName,
          debugShowCheckedModeBanner: false,
          theme: famioTheme(
            Brightness.light,
            highContrast: state.highContrast.value,
          ),
          darkTheme: famioTheme(
            Brightness.dark,
            highContrast: state.highContrast.value,
          ),
          // "Kontrast erhöhen" in the system settings (iOS, macOS) as well.
          highContrastTheme: famioTheme(Brightness.light, highContrast: true),
          highContrastDarkTheme: famioTheme(
            Brightness.dark,
            highContrast: true,
          ),
          scrollBehavior: const FamioScrollBehavior(),
          locale: Locale(appLanguage),
          supportedLocales: L10n.supportedLocales,
          localizationsDelegates: const [
            L10n.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
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
                  tr.appNoSystemKeychainAvailable,
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(tr.appFamioCannotStoreSign, textAlign: TextAlign.center),
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
                      : Text(tr.appAllowUnprotectedStorage),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
