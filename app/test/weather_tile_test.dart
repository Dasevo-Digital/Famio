// The weather tile stays on screen for hours (start page on a tablet, wall
// display): it loads again on its own and when the app comes back, and old
// weather is shown with its time instead of as "now".
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/weather/weather.dart';
import 'package:famio/src/weather/weather_tile.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _home = Place(id: 'p', name: 'Zuhause', latitude: 53.55, longitude: 10);

/// An Open-Meteo answer: 4 °C, cloudy, from [now] on.
Map<String, Object?> _meteo(DateTime now) {
  String hour(int h) => DateTime(
    now.year,
    now.month,
    now.day,
    now.hour + h,
  ).toIso8601String().substring(0, 16);
  return {
    'current': {
      'time': hour(0),
      'temperature_2m': 4.0,
      'apparent_temperature': 2.0,
      'weather_code': 3,
      'wind_speed_10m': 5.0,
      'uv_index': 0.0,
    },
    'hourly': {
      'time': [for (var h = 0; h < 24; h++) hour(h)],
      'temperature_2m': List.filled(24, 4.0),
      'apparent_temperature': List.filled(24, 2.0),
      'precipitation_probability': List.filled(24, 0),
      'weather_code': List.filled(24, 3),
      'uv_index': List.filled(24, 0.0),
    },
  };
}

/// The forecast stored as fetched at [fetched].
String _cache(DateTime fetched) => jsonEncode({
  'key':
      '${WeatherService.round(_home.latitude)},'
      '${WeatherService.round(_home.longitude)}',
  'fetched': fetched.toIso8601String(),
  'data': _meteo(fetched),
});

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  var requests = 0;
  var online = true;
  final client = MockClient((_) async {
    requests++;
    return online
        ? http.Response(
            jsonEncode(_meteo(clock.now())),
            200,
            headers: {'content-type': 'application/json'},
          )
        : http.Response('', 503);
  });

  /// The tile on its own page, with a child; [cached] a stored forecast,
  /// [reachable] whether Open-Meteo answers.
  Future<void> show(
    WidgetTester tester, {
    DateTime? cached,
    bool reachable = true,
  }) async {
    requests = 0;
    online = reachable;
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'weather.enabled': true,
      'weather.cache': ?(cached == null ? null : _cache(cached)),
    });
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')
        ..setMeta(
          'members',
          '[{"id":"m1","username":"mama","displayName":"Mama"}]',
        ),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    engine
      ..savePlace(_home)
      ..saveChild(
        Child(
          id: 'c1',
          name: 'Mia',
          birthDate: DateTime(2020, 5, 4),
          guardianIds: const ['m1'],
        ),
      );
    state
      ..me = const FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama')
      ..engine = engine;
    final service = WeatherService(
      await SharedPreferences.getInstance(),
      client: client,
    );
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: ListView(
                children: [WeatherTile(engine: engine, service: service)],
              ),
            ),
          ),
        );
    await tester.pump();
    // The page in front of the start page (with its own tile) for good.
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
  }

  testWidgets('loads again while it stays on screen', (tester) async {
    await show(tester);
    expect(requests, 1);
    expect(find.text('4° · Bewölkt · gefühlt 2°'), findsOneWidget);
    expect(find.text('Wetter & Kleidung'), findsOneWidget);
    // Fresh for 30 minutes: no new request.
    await tester.pump(const Duration(minutes: 20));
    await settle(tester);
    expect(requests, 1);
    // Then the tile asks again on its own.
    await tester.pump(const Duration(minutes: 15));
    await settle(tester);
    expect(requests, 2);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('loads again when the app comes back', (tester) async {
    await show(tester);
    expect(requests, 1);
    // Away for an hour: a phone app sleeps, no timer runs meanwhile …
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await settle(tester);
    expect(requests, 1);
    // … and back.
    await withClock(
      Clock.fixed(clock.now().add(const Duration(hours: 1))),
      () async {
        for (final s in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(s);
        }
        await settle(tester);
      },
    );
    expect(requests, 2);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('old weather says when it was, and gives no clothing tips', (
    tester,
  ) async {
    final fetched = clock.now().subtract(const Duration(hours: 4));
    await show(tester, cached: fetched, reachable: false);
    expect(requests, 1);
    expect(find.textContaining('Stand '), findsOneWidget);
    expect(find.textContaining(': 4° · Bewölkt'), findsOneWidget);
    expect(find.textContaining('gefühlt'), findsNothing);
    expect(find.textContaining('Mia'), findsNothing);
    expect(
      find.text(
        'Kleidungstipps gibt es wieder, sobald neue Wetterdaten da sind.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 1));
  });
}

/// Lets the requests and the stored forecast finish.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(Durations.short2));
    await tester.pump();
  }
}
