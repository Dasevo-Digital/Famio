import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/family_data.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import 'weather.dart';

String _deg(double v) => '${v.round()}°';

/// Dashboard tile: weather at home and what the children should wear.
class WeatherTile extends StatefulWidget {
  const WeatherTile({super.key, required this.engine, this.service});

  final SyncEngine engine;

  /// For tests.
  final WeatherService? service;

  @override
  State<WeatherTile> createState() => _WeatherTileState();
}

class _WeatherTileState extends State<WeatherTile> {
  WeatherService? _service;
  WeatherForecast? _forecast;
  var _loading = false;
  String? _placeKey;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final service =
        widget.service ?? WeatherService(await SharedPreferences.getInstance());
    if (!mounted) return;
    setState(() => _service = service);
    _load();
  }

  @override
  void didUpdateWidget(WeatherTile old) {
    super.didUpdateWidget(old);
    final place = weatherPlace(widget.engine.places);
    if (place != null && '${place.latitude},${place.longitude}' != _placeKey) {
      _load();
    }
  }

  Future<void> _load({bool force = false}) async {
    final service = _service;
    final place = weatherPlace(widget.engine.places);
    if (service == null || place == null || !service.enabled) return;
    _placeKey = '${place.latitude},${place.longitude}';
    setState(() {
      _forecast ??= service.cached(place);
      _loading = true;
    });
    final f = await service.forecast(place, force: force);
    if (mounted) {
      setState(() {
        _forecast = f ?? _forecast;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final service = _service;
    final place = weatherPlace(widget.engine.places);
    final kids = widget.engine.children
        .where((k) => k.ageInMonths(DateTime.now()) < 12 * 12)
        .toList();
    Widget frame(Widget child, {VoidCallback? onTap, String? badge}) =>
        SoftCard(
          color: c.tint(FamioSection.location),
          onTap: onTap,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconBlob(
                    AppIcons.cloudSun,
                    color: c.strong(FamioSection.location),
                    background: c.surface.withValues(alpha: 0.7),
                    size: 42,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      kids.isEmpty ? 'Wetter' : 'Wetter & Kleidung',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  if (badge != null)
                    Text(badge, style: theme.textTheme.headlineSmall),
                ],
              ),
              const SizedBox(height: 14),
              child,
            ],
          ),
        );

    if (service == null) return frame(const SizedBox(height: 20));
    if (!service.enabled) {
      return frame(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Was sollen die Kinder anziehen? Famio fragt dafür das Wetter '
              'bei Open-Meteo ab – übertragen werden nur die ungefähren '
              'Koordinaten eures Orts „Zuhause“ (auf ~1 km gerundet).',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            FilledButton.tonal(
              onPressed: () async {
                await service.setEnabled(true);
                if (mounted) setState(() {});
                _load(force: true);
              },
              child: const Text('Wetter einschalten'),
            ),
          ],
        ),
      );
    }
    if (place == null) {
      return frame(
        Text(
          'Lege unter Standort → Orte einen Ort „Zuhause“ an – dafür gibt '
          'es dann das Wetter.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    final f = _forecast;
    if (f == null) {
      return frame(
        _loading
            ? const LinearProgressIndicator()
            : Text(
                'Wetter gerade nicht erreichbar.',
                style: theme.textTheme.bodySmall,
              ),
      );
    }
    // In the evening the tile tells what the children sleep in; the
    // details show both.
    final hour = DateTime.now().hour;
    final night = hour >= 17 || hour < 6
        ? <String, NightAdvice>{for (final k in kids) k.id: ?nightAdvice(k, f)}
        : const <String, NightAdvice>{};
    return frame(
      onTap: () => _showDetails(context, f, place, kids),
      badge: weatherEmoji(f.now.code),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            night.isEmpty
                ? '${_deg(f.now.temperature)} · ${weatherText(f.now.code)} · '
                      'gefühlt ${_deg(f.now.apparent)}'
                : '${_deg(f.now.temperature)} · ${weatherText(f.now.code)} · '
                      '🌙 nachts bis ${_deg(night.values.first.low)}',
            style: theme.textTheme.bodyLarge,
          ),
          for (final k in kids.take(4))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: night.containsKey(k.id)
                          ? '${k.name} heute Nacht: '
                          : '${k.name}: ',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    TextSpan(
                      text:
                          night[k.id]?.items.join(', ') ??
                          clothingAdvice(k, f).items.take(3).join(', '),
                    ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }

  void _showDetails(
    BuildContext context,
    WeatherForecast f,
    Place place,
    List<Child> kids,
  ) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${weatherEmoji(f.now.code)} ${_deg(f.now.temperature)} in ${place.name}',
                  style: theme.textTheme.headlineSmall,
                ),
                Text(
                  '${weatherText(f.now.code)} · gefühlt ${_deg(f.now.apparent)}'
                  '${f.now.windKmh == null ? '' : ' · Wind ${f.now.windKmh!.round()} km/h'}'
                  '${f.now.uvIndex == null ? '' : ' · UV ${f.now.uvIndex!.toStringAsFixed(0)}'}',
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 86,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final h in f.hours.take(12))
                        Container(
                          width: 58,
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          decoration: BoxDecoration(
                            color: FamioColors.of(context).surfaceSoft,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            children: [
                              Text(
                                DateFormat('HH', 'de').format(h.time),
                                style: theme.textTheme.labelSmall,
                              ),
                              Text(weatherEmoji(h.code)),
                              Text(_deg(h.temperature)),
                              if ((h.precipitationProbability ?? 0) >= 20)
                                Text(
                                  '${h.precipitationProbability}%',
                                  style: theme.textTheme.labelSmall,
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                for (final k in kids) ...[
                  const SizedBox(height: 16),
                  () {
                    final advice = clothingAdvice(k, f);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${k.name} · ${advice.summary}',
                          style: theme.textTheme.titleMedium,
                        ),
                        for (final item in advice.items) Text('• $item'),
                        for (final e in advice.extras)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              e,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    );
                  }(),
                ],
                if (kids.isNotEmpty && nightAdvice(kids.first, f) != null) ...[
                  const SizedBox(height: 24),
                  Text(
                    '🌙 Für die Nacht · draußen bis ${_deg(nightAdvice(kids.first, f)!.low)}',
                    style: theme.textTheme.titleLarge,
                  ),
                  for (final k in kids)
                    if (nightAdvice(k, f) case final n?) ...[
                      const SizedBox(height: 12),
                      Text(
                        '${k.name} · ${n.summary}',
                        style: theme.textTheme.titleMedium,
                      ),
                      for (final item in n.items) Text('• $item'),
                    ],
                  const SizedBox(height: 8),
                  for (final h in {
                    for (final k in kids) ...?nightAdvice(k, f)?.hints,
                  })
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        h,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                Text(
                  'Tagsüber: Faustregeln für die nächsten 3 Stunden nach gefühlter '
                  'Temperatur. Nachts: nach der Tiefsttemperatur draußen – '
                  'entscheidend ist die Zimmertemperatur. Wetterdaten: Open-Meteo.com (CC BY 4.0), '
                  'Stand ${DateFormat('HH:mm', 'de').format(f.fetched)}.',
                  style: theme.textTheme.bodySmall,
                ),
                TextButton(
                  onPressed: () async {
                    await _service?.setEnabled(false);
                    if (context.mounted) Navigator.pop(context);
                    if (mounted) setState(() => _forecast = null);
                  },
                  child: const Text('Wetter auf diesem Gerät ausschalten'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
