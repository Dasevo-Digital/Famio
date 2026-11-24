import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'design/theme.dart';
import 'screens/security_screens.dart';
import 'screens/connect_screen.dart';
import 'screens/home_shell.dart';
import 'screens/location/pause_dialog.dart';
import 'security/app_lock.dart';
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
        listenable: Listenable.merge([
          state.highContrast,
          state.themeMode,
          state.language,
        ]),
        builder: (context, _) => MaterialApp(
          // A new language rebuilds everything, also the texts of widgets
          // that would otherwise stay as they are.
          key: ValueKey(appLanguage),
          navigatorObservers: [state.openRoutes],
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
          themeMode: state.themeMode.value,
          scrollBehavior: const FamioScrollBehavior(),
          locale: Locale(appLanguage),
          supportedLocales: L10n.supportedLocales,
          localizationsDelegates: const [
            L10n.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          builder: (context, child) {
            var result = _hours24(context, child!);
            // The development build says so on every screen.
            if (AppEnv.isDev) {
              result = Banner(
                message: 'DEV',
                location: BannerLocation.topEnd,
                color: const Color(0xFFE8703A),
                child: result,
              );
            }
            final content = result;
            return ListenableBuilder(
              listenable: state,
              builder: (_, _) => AppLockGate(
                lock: state.lock,
                active: state.me != null,
                onSignOut: (proceed) => state.signOut(proceed: proceed),
                // Also here only with the parents' code (#337), when one
                // is needed (#595).
                sharingNeedsCode: () => endingSharingNeedsCode(state),
                endSharing: (code) async {
                  final engine = state.engine;
                  final me = state.me;
                  if (engine == null || me == null) return null;
                  try {
                    await endSharingOnThisPhone(engine.api, me, code);
                    return null;
                  } on ApiError catch (e) {
                    return e.message;
                  } catch (_) {
                    return tr.locationSharingNotEnded;
                  }
                },
                child: content,
              ),
            );
          },
          home: const _Root(),
          // Famio has no named pages: an address the platform still hands
          // over as one (deep linking is off) is dropped, not an error.
          onUnknownRoute: _DroppedRoute.new,
        ),
      ),
    );
  }
}

/// A route for an address Famio has no page for: shows nothing and removes
/// itself right away.
class _DroppedRoute extends PageRouteBuilder<void> {
  _DroppedRoute(RouteSettings settings)
    : super(
        settings: settings,
        opaque: false,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => const _Drop(),
      );
}

class _Drop extends StatefulWidget {
  const _Drop();

  @override
  State<_Drop> createState() => _DropState();
}

class _DropState extends State<_Drop> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) route.navigator?.removeRoute(route);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// German and Spanish write times with 24 hours, also on a phone set to 12.
/// The time picker shows them so, but its text mode checks the hour against
/// the phone's setting alone: there, "16" was refused. With the language's
/// own clock as the app's setting, both agree.
Widget _hours24(BuildContext context, Widget child) {
  final format = MaterialLocalizations.of(context).timeOfDayFormat();
  if (MediaQuery.alwaysUse24HourFormatOf(context) ||
      hourFormat(of: format) == HourFormat.h) {
    return child;
  }
  return MediaQuery(
    data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
    child: child,
  );
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
