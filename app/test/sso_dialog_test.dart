import 'dart:async';

import 'package:famio/src/screens/security_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Keeps the browser closed and notes what it was asked to open.
class _FakeLauncher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

void main() {
  testWidgets('the sign-in dialog shows the code the browser asks for', (
    tester,
  ) async {
    final launcher = _FakeLauncher();
    final before = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = before);
    final done = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => runSsoInBrowser(
              context,
              label: 'Authentik',
              run: (open, cancelled) async {
                await open(
                  Uri.parse('https://idp.example/authorize'),
                  '482913',
                );
                await done.future;
              },
            ),
            child: const Text('los'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('los'));
    // The spinner never settles: pump through the dialog's entrance.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(launcher.opened, ['https://idp.example/authorize']);
    expect(find.text('482913'), findsOneWidget);
    expect(
      find.text('Im Browser fragt Famio nach der Anmeldung nach diesem Code:'),
      findsOneWidget,
    );
    done.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('482913'), findsNothing);
  });
}
