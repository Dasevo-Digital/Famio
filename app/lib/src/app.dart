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
      child: MaterialApp(
        title: AppEnv.appName,
        debugShowCheckedModeBanner: false,
        theme: famioTheme(Brightness.light),
        darkTheme: famioTheme(Brightness.dark),
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
      child: !state.signedIn
          ? const ConnectScreen(key: ValueKey('connect'))
          : state.twoFactorGate != null
          // An admin made two-factor login mandatory: nothing else first.
          ? const TwoFactorGateScreen(key: ValueKey('two-factor'))
          : const HomeShell(key: ValueKey('home')),
    );
  }
}
