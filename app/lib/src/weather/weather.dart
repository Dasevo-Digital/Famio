import 'dart:convert';

import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// One hour (or the current conditions) of the forecast.
class WeatherHour {
  const WeatherHour({
    required this.time,
    required this.temperature,
    required this.apparent,
    required this.code,
    this.precipitationProbability,
    this.precipitation,
    this.uvIndex,
    this.windKmh,
  });

  final DateTime time;
  final double temperature;

  /// Felt temperature (wind, humidity).
  final double apparent;

  /// WMO weather code.
  final int code;
  final int? precipitationProbability;
  final double? precipitation;
  final double? uvIndex;
  final double? windKmh;

  bool get rainy =>
      (code >= 51 && code <= 67) ||
      (code >= 80 && code <= 82) ||
      code >= 95 ||
      (precipitationProbability ?? 0) >= 50;

  bool get snowy => (code >= 71 && code <= 77) || code == 85 || code == 86;
}

class WeatherForecast {
  const WeatherForecast({
    required this.fetched,
    required this.now,
    required this.hours,
  });

  /// Parses an Open-Meteo `forecast` answer.
  factory WeatherForecast.fromOpenMeteo(
    Map<String, Object?> json, {
    DateTime? fetched,
  }) {
    final current = (json['current'] as Map).cast<String, Object?>();
    final hourly = (json['hourly'] as Map).cast<String, Object?>();
    double d(Object? v) => (v as num?)?.toDouble() ?? 0;
    final times = (hourly['time'] as List).cast<String>();
    List<Object?> col(String k) =>
        hourly[k] as List? ?? List.filled(times.length, null);
    final temps = col('temperature_2m');
    final felt = col('apparent_temperature');
    final codes = col('weather_code');
    final rain = col('precipitation_probability');
    final uv = col('uv_index');
    return WeatherForecast(
      fetched: fetched ?? DateTime.now(),
      now: WeatherHour(
        time: DateTime.parse(current['time'] as String),
        temperature: d(current['temperature_2m']),
        apparent: d(current['apparent_temperature']),
        code: (current['weather_code'] as num?)?.toInt() ?? 0,
        precipitation: (current['precipitation'] as num?)?.toDouble(),
        uvIndex: (current['uv_index'] as num?)?.toDouble(),
        windKmh: (current['wind_speed_10m'] as num?)?.toDouble(),
      ),
      hours: [
        for (var i = 0; i < times.length; i++)
          WeatherHour(
            time: DateTime.parse(times[i]),
            temperature: d(temps[i]),
            apparent: d(felt[i]),
            code: (codes[i] as num?)?.toInt() ?? 0,
            precipitationProbability: (rain[i] as num?)?.toInt(),
            uvIndex: (uv[i] as num?)?.toDouble(),
          ),
      ],
    );
  }

  final DateTime fetched;
  final WeatherHour now;

  /// The next hours (local time of the place).
  final List<WeatherHour> hours;
}

/// German description of a WMO weather code.
String weatherText(int code) => switch (code) {
  0 => 'Klar',
  1 => 'Überwiegend klar',
  2 => 'Teils bewölkt',
  3 => 'Bewölkt',
  45 || 48 => 'Nebel',
  >= 51 && <= 57 => 'Nieselregen',
  >= 61 && <= 67 => 'Regen',
  >= 71 && <= 77 => 'Schnee',
  >= 80 && <= 82 => 'Regenschauer',
  85 || 86 => 'Schneeschauer',
  >= 95 => 'Gewitter',
  _ => 'Wetter',
};

String weatherEmoji(int code) => switch (code) {
  0 || 1 => '☀️',
  2 => '⛅',
  3 => '☁️',
  45 || 48 => '🌫️',
  >= 51 && <= 67 => '🌧️',
  >= 71 && <= 77 => '❄️',
  >= 80 && <= 82 => '🌦️',
  85 || 86 => '🌨️',
  >= 95 => '⛈️',
  _ => '🌡️',
};

/// The family's home for the weather: a place called "Zuhause" (or home,
/// daheim), else the first place.
Place? weatherPlace(List<Place> places) =>
    places
        .where(
          (p) => RegExp(
            r'zuhause|zu hause|home|daheim',
            caseSensitive: false,
          ).hasMatch(p.name),
        )
        .firstOrNull ??
    places.firstOrNull;

/// Fetches and caches the forecast from Open-Meteo (no account needed).
/// Only the rounded coordinates of the home place leave the device.
class WeatherService {
  WeatherService(this._prefs, {http.Client? client, Uri? endpoint})
    : _http = client ?? http.Client(),
      _endpoint =
          endpoint ?? Uri.parse('https://api.open-meteo.com/v1/forecast');

  final SharedPreferences _prefs;
  final http.Client _http;
  final Uri _endpoint;

  static const _enabledKey = 'weather.enabled';
  static const _cacheKey = 'weather.cache';
  static const maxAge = Duration(minutes: 30);

  /// The user agreed to ask Open-Meteo (per device).
  bool get enabled => _prefs.getBool(_enabledKey) ?? false;

  Future<void> setEnabled(bool value) async {
    await _prefs.setBool(_enabledKey, value);
    if (!value) await _prefs.remove(_cacheKey);
  }

  /// Rounded to 0.01° (about 1 km).
  static double round(double v) => (v * 100).round() / 100;

  /// The cached forecast for [place], if any.
  WeatherForecast? cached(Place place) {
    final raw = _prefs.getString(_cacheKey);
    if (raw == null) return null;
    try {
      final json = (jsonDecode(raw) as Map).cast<String, Object?>();
      if (json['key'] != _key(place)) return null;
      return WeatherForecast.fromOpenMeteo(
        (json['data'] as Map).cast(),
        fetched: DateTime.parse(json['fetched'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  String _key(Place p) => '${round(p.latitude)},${round(p.longitude)}';

  /// The forecast for [place]: from the cache while fresh, else from
  /// Open-Meteo (falling back to the cache when offline).
  Future<WeatherForecast?> forecast(Place place, {bool force = false}) async {
    final old = cached(place);
    if (!force &&
        old != null &&
        DateTime.now().difference(old.fetched) < maxAge) {
      return old;
    }
    try {
      final response = await _http
          .get(
            _endpoint.replace(
              queryParameters: {
                'latitude': '${round(place.latitude)}',
                'longitude': '${round(place.longitude)}',
                'current':
                    'temperature_2m,apparent_temperature,precipitation,'
                    'weather_code,wind_speed_10m,uv_index,is_day',
                'hourly':
                    'temperature_2m,apparent_temperature,'
                    'precipitation_probability,weather_code,uv_index',
                'forecast_hours': '12',
                'timezone': 'auto',
              },
            ),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return old;
      final data = (jsonDecode(response.body) as Map).cast<String, Object?>();
      final now = DateTime.now();
      await _prefs.setString(
        _cacheKey,
        jsonEncode({
          'key': _key(place),
          'fetched': now.toIso8601String(),
          'data': data,
        }),
      );
      return WeatherForecast.fromOpenMeteo(data, fetched: now);
    } catch (_) {
      return old;
    }
  }
}

/// What a child should wear, from the felt temperature of the next hours.
class ClothingAdvice {
  const ClothingAdvice({
    required this.summary,
    required this.items,
    this.extras = const [],
  });

  /// Short line for the dashboard.
  final String summary;
  final List<String> items;

  /// Rain, sun, wind and baby hints.
  final List<String> extras;
}

/// General rules of thumb (like BabyWeather): babies need one layer more
/// than adults when they are carried or lie in the pram.
ClothingAdvice clothingAdvice(
  Child child,
  WeatherForecast w, {
  DateTime? at,
  Duration outing = const Duration(hours: 3),
}) {
  final now = at ?? DateTime.now();
  final next = [
    w.now,
    ...w.hours.where(
      (h) =>
          !h.time.isBefore(now.subtract(const Duration(hours: 1))) &&
          h.time.isBefore(now.add(outing)),
    ),
  ];
  final felt = next.map((h) => h.apparent).reduce((a, b) => a < b ? a : b);
  final rain = next.any((h) => h.rainy);
  final snow = next.any((h) => h.snowy);
  final uv = next
      .map((h) => h.uvIndex ?? 0)
      .fold<double>(0, (a, b) => a > b ? a : b);
  final wind = (w.now.windKmh ?? 0) >= 30;
  final months = child.ageInMonths(now);
  final baby = months < 12;
  final toddler = months < 36;

  final (summary, items) = switch (felt) {
    >= 26 => (
      'luftig',
      [
        baby ? 'Kurzarm-Body' : 'T-Shirt oder Top',
        if (!baby) 'kurze Hose oder Kleid',
        'Sonnenhut mit Nackenschutz',
      ],
    ),
    >= 20 => (
      'leicht',
      [
        baby ? 'Body kurz + dünne Hose' : 'T-Shirt',
        if (!baby) 'dünne lange Hose oder Rock',
        'Sonnenhut',
        if (baby) 'dünne Jacke oder Decke im Schatten',
      ],
    ),
    >= 15 => (
      'Übergang',
      [
        baby ? 'Langarm-Body + Strampler' : 'Langarmshirt',
        if (!baby) 'lange Hose',
        baby ? 'Strickjacke' : 'dünne Jacke oder Pulli',
        if (toddler) 'dünne Mütze bei Wind',
      ],
    ),
    >= 10 => (
      'Jacke',
      [
        baby ? 'Langarm-Body + Pulli' : 'Pulli',
        'Übergangsjacke',
        'Mütze',
        if (baby) 'Söckchen oder Schühchen',
      ],
    ),
    >= 5 => (
      'warm',
      [
        baby ? 'Wollbody + Pulli' : 'Pulli',
        baby ? 'gefütterter Overall' : 'warme Jacke',
        'Mütze',
        'Schal oder Halstuch',
        if (baby) 'Fußsack oder Decke',
      ],
    ),
    >= 0 => (
      'Winter',
      [
        baby ? 'Wollbody + Strumpfhose' : 'Thermo-Unterhemd oder Pulli',
        baby ? 'Winteroverall' : 'Winterjacke',
        'Wintermütze',
        'Handschuhe',
        'Schal',
        if (baby) 'warmer Fußsack',
      ],
    ),
    _ => (
      'eisig',
      [
        'Woll-Unterwäsche',
        baby
            ? 'dicker Winteroverall'
            : 'Schneeanzug oder Winterjacke + Schneehose',
        'dicke Mütze',
        'Fäustlinge',
        'Schal',
        'gefütterte Winterschuhe',
        if (baby) 'Fußsack, nicht zu lange draußen',
      ],
    ),
  };
  final extras = [
    if (snow)
      toddler
          ? 'Schnee: Matschhose und Stiefel'
          : 'Schnee: Schneehose und Stiefel'
    else if (rain)
      baby
          ? 'Regen: Regenschutz für Kinderwagen oder Trage'
          : 'Regen: Regenjacke, Matschhose, Gummistiefel',
    if (wind && felt < 20) 'Windig: winddichte Jacke, Ohren bedecken',
    if (uv >= 3)
      baby
          ? 'Sonne: Babys unter 1 Jahr in den Schatten, Sonnenhut'
          : 'Sonne: Sonnencreme (LSF 30+), Sonnenhut',
    if (baby && felt < 15)
      'Babys: eine Schicht mehr als du – Nacken fühlen, nicht die Hände',
  ];
  return ClothingAdvice(summary: summary, items: items, extras: extras);
}
