import 'dart:convert';

import 'package:famio/src/data/birthdays.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/weather/weather.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _meteo({
  double felt = 7,
  int code = 61,
  double uv = 0,
  double wind = 10,
}) => {
  'current': {
    'time': '2026-11-02T09:00',
    'temperature_2m': felt + 2,
    'apparent_temperature': felt,
    'precipitation': 0.4,
    'weather_code': code,
    'wind_speed_10m': wind,
    'uv_index': uv,
  },
  'hourly': {
    'time': [
      for (var h = 9; h < 21; h++)
        '2026-11-02T${h.toString().padLeft(2, '0')}:00',
    ],
    'temperature_2m': List.filled(12, felt + 2),
    'apparent_temperature': List.filled(12, felt),
    'precipitation_probability': List.filled(12, code >= 61 ? 80 : 0),
    'weather_code': List.filled(12, code),
    'uv_index': List.filled(12, uv),
  },
};

void main() {
  final at = DateTime(2026, 11, 2, 9);
  final baby = Child(id: 'b', name: 'Emil', birthDate: DateTime(2026, 8, 1));
  final big = Child(id: 'k', name: 'Lena', birthDate: DateTime(2019, 3, 4));

  test('clothing follows felt temperature, age, rain and sun', () {
    final cold = WeatherForecast.fromOpenMeteo(_meteo());
    final forBaby = clothingAdvice(baby, cold, at: at);
    expect(forBaby.summary, 'warm');
    expect(forBaby.items, contains('gefütterter Overall'));
    expect(forBaby.extras.join(), contains('Regenschutz für Kinderwagen'));
    expect(forBaby.extras.join(), contains('eine Schicht mehr'));
    final forBig = clothingAdvice(big, cold, at: at);
    expect(forBig.items, contains('warme Jacke'));
    expect(forBig.extras.join(), contains('Gummistiefel'));

    final summer = WeatherForecast.fromOpenMeteo(
      _meteo(felt: 28, code: 0, uv: 7),
    );
    expect(clothingAdvice(big, summer, at: at).summary, 'luftig');
    expect(
      clothingAdvice(baby, summer, at: at).extras.join(),
      contains('Schatten'),
    );
    final frost = WeatherForecast.fromOpenMeteo(_meteo(felt: -6, code: 71));
    expect(clothingAdvice(big, frost, at: at).items, contains('Fäustlinge'));
    expect(
      clothingAdvice(big, frost, at: at).extras.join(),
      contains('Schnee'),
    );
  });

  test('night advice follows the low of tonight and the age', () {
    Map<String, Object?> night(double Function(int hour) temp) => {
      'current': {
        'time': '2026-11-02T18:00',
        'temperature_2m': temp(18),
        'apparent_temperature': temp(18),
        'weather_code': 0,
      },
      'hourly': {
        'time': [
          for (var i = 0; i < 24; i++)
            DateTime(2026, 11, 2, 18 + i).toIso8601String().substring(0, 16),
        ],
        'temperature_2m': [for (var i = 0; i < 24; i++) temp((18 + i) % 24)],
        'apparent_temperature': [
          for (var i = 0; i < 24; i++) temp((18 + i) % 24) - 3,
        ],
        'weather_code': List.filled(24, 0),
      },
    };
    final evening = DateTime(2026, 11, 2, 19);
    // 4 °C at 5 o'clock – the warm afternoon of tomorrow does not count.
    final cold = WeatherForecast.fromOpenMeteo(
      night((h) => h == 5 ? 4 : (h >= 12 && h < 18 ? 25 : 9)),
    );
    final forBaby = nightAdvice(baby, cold, at: evening)!;
    expect(forBaby.low, 4);
    expect(forBaby.summary, 'kalt');
    expect(forBaby.items.join(), contains('Schlafsack'));
    expect(forBaby.hints.join(), contains('ohne Decke'));
    final forBig = nightAdvice(big, cold, at: evening)!;
    expect(forBig.items, contains('warme Bettdecke'));
    expect(forBig.hints.join(), isNot(contains('ohne Decke')));

    final tropical = WeatherForecast.fromOpenMeteo(night((_) => 22));
    expect(nightAdvice(big, tropical, at: evening)!.summary, 'sehr warm');
    // After midnight it is still the same night.
    expect(nightOf(DateTime(2026, 11, 3, 2)).$2, DateTime(2026, 11, 3, 6));
    // No forecast for the night: no advice.
    expect(
      nightAdvice(big, WeatherForecast.fromOpenMeteo(_meteo()), at: at),
      isNull,
    );
  });

  test('weather service rounds the place, caches and works offline', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var calls = 0;
    Uri? asked;
    var online = true;
    final service = WeatherService(
      prefs,
      client: MockClient((request) async {
        calls++;
        asked = request.url;
        if (!online) throw http.ClientException('offline');
        return http.Response(jsonEncode(_meteo()), 200);
      }),
    );
    const home = Place(
      id: 'p',
      name: 'Zuhause',
      latitude: 53.57612,
      longitude: 9.99871,
    );
    expect(service.enabled, isFalse);
    await service.setEnabled(true);
    final f = await service.forecast(home);
    expect(f!.now.apparent, 7);
    expect(asked!.queryParameters['latitude'], '53.58');
    expect(asked!.queryParameters['longitude'], '10.0');
    await service.forecast(home);
    expect(calls, 1, reason: 'fresh cache');
    online = false;
    expect((await service.forecast(home, force: true))?.now.code, 61);
    await service.setEnabled(false);
    expect(service.cached(home), isNull);
  });

  test('home place is "Zuhause" or the first place', () {
    const school = Place(id: 's', name: 'Schule', latitude: 1, longitude: 1);
    const home = Place(
      id: 'h',
      name: 'Unser Zuhause',
      latitude: 2,
      longitude: 2,
    );
    expect(weatherPlace([school, home])?.id, 'h');
    expect(weatherPlace([school])?.id, 's');
    expect(weatherPlace([]), isNull);
  });

  test('birthdays of members, children and contacts', () {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')
        ..setMeta(
          'members',
          '[{"id":"m1","username":"mama","displayName":"Mama","birthday":"1985-11-05"}]',
        ),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    engine
      ..saveChild(
        Child(id: 'c1', name: 'Mia', birthDate: DateTime(2024, 11, 2)),
      )
      ..saveContact(
        const FamilyContact(
          id: 'o',
          name: 'Oma Inge',
          birthday: Birthday(12, 24),
        ),
      );
    final soon = upcomingBirthdays(engine, DateTime(2026, 11, 2, 7));
    expect(soon.map((e) => e.$1.headline(e.$2)), [
      'Mia wird 2',
      'Mama wird 41',
    ]);
    expect(
      upcomingBirthdays(engine, DateTime(2026, 11, 2), days: 60),
      hasLength(3),
    );
    // Yearly all-day entries in the calendar.
    final dec = engine.occurrences(DateTime(2026, 12, 1), DateTime(2027, 1, 1));
    expect(dec.single.event.title, '🎂 Oma Inge');
    expect(isBirthdaySource(dec.single.event.sourceId), isTrue);
    // 29 February in other years.
    expect(
      const Birthday(2, 29, 2020).next(DateTime(2026, 2, 1)),
      DateTime(2026, 2, 28),
    );
  });
}
