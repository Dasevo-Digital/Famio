part of '../location_screens.dart';

class LocationHistoryScreen extends StatefulWidget {
  const LocationHistoryScreen({super.key, required this.member});

  final FamilyMember member;

  @override
  State<LocationHistoryScreen> createState() => _LocationHistoryScreenState();
}

class _LocationHistoryScreenState extends State<LocationHistoryScreen> {
  var _day = DateUtils.dateOnly(DateTime.now());
  late Future<List<LocationFix>> _points = _load();
  final _map = MapController();

  Future<List<LocationFix>> _load() =>
      AppScope.read(context).engine!.api.locationHistory(
        memberId: widget.member.id,
        from: _day,
        to: _day.add(const Duration(days: 1)),
      );

  void _pick(DateTime day) => setState(() {
    _day = day;
    _points = _load();
  });

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.of(context).engine!;
    final c = FamioColors.of(context);
    final accent = Color(widget.member.color ?? 0xFF16927F);
    final today = DateUtils.dateOnly(DateTime.now());
    final days = [
      for (var i = 0; i < 7; i++) today.subtract(Duration(days: i)),
    ];
    final time = DateFormat('HH:mm', 'de');
    return SectionPage(
      section: FamioSection.location,
      title: 'Verlauf',
      subtitle: '${widget.member.displayName} · letzte 7 Tage',
      bodyPadding: EdgeInsets.zero,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final d in days)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        d == today
                            ? 'Heute'
                            : d == today.subtract(const Duration(days: 1))
                            ? 'Gestern'
                            : DateFormat('E d.M.', 'de').format(d),
                      ),
                      selected: d == _day,
                      onSelected: (_) => _pick(d),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder(
              future: _points,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return EmptyHint(
                    icon: AppIcons.cloudSlash,
                    color: c.strong(FamioSection.location),
                    text: 'Verlauf nicht verfügbar: ${snapshot.error}',
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final points = snapshot.data!;
                if (points.isEmpty) {
                  return EmptyHint(
                    icon: AppIcons.route,
                    color: c.strong(FamioSection.location),
                    text: 'An diesem Tag wurde kein Standort geteilt.',
                  );
                }
                final line = [
                  for (final p in points) LatLng(p.latitude, p.longitude),
                ];
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: FlutterMap(
                            key: ValueKey(_day),
                            mapController: _map,
                            options: MapOptions(
                              initialCenter: line.last,
                              initialZoom: 14,
                              initialCameraFit: line.length > 1
                                  ? CameraFit.coordinates(
                                      coordinates: line,
                                      padding: const EdgeInsets.all(40),
                                      maxZoom: 16,
                                    )
                                  : null,
                            ),
                            children: [
                              tileLayer(context),
                              CircleLayer(
                                circles: [
                                  for (final p in engine.places)
                                    CircleMarker(
                                      point: LatLng(p.latitude, p.longitude),
                                      radius: p.radius,
                                      useRadiusInMeter: true,
                                      color: c
                                          .strong(FamioSection.location)
                                          .withValues(alpha: 0.12),
                                    ),
                                ],
                              ),
                              PolylineLayer(
                                polylines: [
                                  Polyline(
                                    points: line,
                                    strokeWidth: 4,
                                    color: accent,
                                  ),
                                ],
                              ),
                              MarkerLayer(
                                markers: [
                                  for (final (i, p) in [
                                    (0, points.first),
                                    (1, points.last),
                                  ])
                                    Marker(
                                      point: LatLng(p.latitude, p.longitude),
                                      width: 64,
                                      height: 28,
                                      child: Container(
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: i == 0 ? c.surface : accent,
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          border: Border.all(color: accent),
                                        ),
                                        child: Text(
                                          time.format(p.at.toLocal()),
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: i == 0
                                                ? accent
                                                : Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              attribution(context),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${points.length} Positionen von '
                        '${time.format(points.first.at.toLocal())} bis '
                        '${time.format(points.last.at.toLocal())} Uhr · '
                        '${(_length(points) / 1000).toStringAsFixed(1)} km',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static double _length(List<LocationFix> points) {
    var sum = 0.0;
    for (var i = 1; i < points.length; i++) {
      sum += distanceMeters(
        points[i - 1].latitude,
        points[i - 1].longitude,
        points[i].latitude,
        points[i].longitude,
      );
    }
    return sum;
  }
}
