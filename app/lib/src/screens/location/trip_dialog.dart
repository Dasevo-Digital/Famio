part of '../location_screens.dart';

/// "Bin unterwegs": pick a family place and how; the arrival is estimated
/// from the own position (as the crow flies, a third added for roads), or
/// set by hand without one. No routing service learns where anyone goes.
Future<void> showTripDialog(BuildContext context, SyncEngine engine) async {
  final places = engine.places;
  if (places.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr.tripNoPlaces)));
    return;
  }
  final mine = engine.memberLocations[engine.memberId];
  final here = mine != null && mine.hasPosition
      ? (mine.latitude!, mine.longitude!)
      : null;
  var place = places.first;
  var mode = TripMode.car;
  var manualMinutes = 15.0;
  final time = DateFormat.Hm(appLanguage);
  final trip = await showDialog<Trip>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final minutes = here == null
            ? manualMinutes.round()
            : Trip.estimate(
                distanceMeters(
                  here.$1,
                  here.$2,
                  place.latitude,
                  place.longitude,
                ),
                mode,
              ).inMinutes;
        final eta = DateTime.now().add(Duration(minutes: minutes));
        return AlertDialog(
          title: Text(tr.tripTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<Place>(
                  initialValue: place,
                  decoration: InputDecoration(labelText: tr.tripPlace),
                  items: [
                    for (final p in places)
                      DropdownMenuItem(value: p, child: Text(p.name)),
                  ],
                  onChanged: (p) => setState(() => place = p ?? place),
                ),
                const SizedBox(height: 16),
                SegmentedButton<TripMode>(
                  showSelectedIcon: false,
                  segments: [
                    for (final (m, icon, label) in [
                      (TripMode.walk, AppIcons.footprints, tr.tripModeWalk),
                      (TripMode.bike, AppIcons.bike, tr.tripModeBike),
                      (TripMode.car, AppIcons.car, tr.tripModeCar),
                      (TripMode.transit, AppIcons.bus, tr.tripModeTransit),
                    ])
                      ButtonSegment(
                        value: m,
                        icon: Icon(icon, size: 18),
                        tooltip: label,
                      ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (s) => setState(() => mode = s.first),
                ),
                const SizedBox(height: 16),
                if (here == null) ...[
                  Text(tr.tripNoPosition),
                  Slider(
                    value: manualMinutes,
                    min: 5,
                    max: 120,
                    divisions: 23,
                    label: '$minutes',
                    onChanged: (v) => setState(() => manualMinutes = v),
                  ),
                ],
                Text(
                  tr.tripEta(time.format(eta), minutes),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(tr.tripHint, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                context,
                Trip(
                  memberId: engine.memberId,
                  placeId: place.id,
                  placeName: place.name,
                  eta: eta,
                  startedAt: DateTime.now(),
                  mode: mode,
                ),
              ),
              child: Text(tr.tripTell),
            ),
          ],
        );
      },
    ),
  );
  if (trip != null) engine.startTrip(trip);
}

/// "unterwegs nach Zuhause, ca. 18:40"
String tripLabel(Trip trip) => tr.tripOnTheWay(
  trip.placeName,
  DateFormat.Hm(appLanguage).format(trip.eta),
);

/// Below the own sharing card: "Bin unterwegs", or the own way with
/// "Angekommen".
class _TripCard extends StatelessWidget {
  const _TripCard({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final trip = engine.tripOf(engine.memberId);
    final accent = FamioColors.of(context).strong(FamioSection.location);
    if (trip == null) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          icon: const Icon(AppIcons.navigation),
          label: Text(tr.tripStart),
          onPressed: () => showTripDialog(context, engine),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SoftCard(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(AppIcons.navigation, color: accent),
            const SizedBox(width: 12),
            Expanded(child: Text(tripLabel(trip))),
            TextButton(onPressed: engine.endTrip, child: Text(tr.tripArrived)),
          ],
        ),
      ),
    );
  }
}
