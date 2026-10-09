part of '../location_screens.dart';

class PlacesScreen extends StatelessWidget {
  const PlacesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final me = AppScope.of(context).me!;
    return SectionPage(
      section: FamioSection.location,
      title: tr.remindersPlaces,
      subtitle: tr.placesReportArrivalsDepartures,
      // This is an extended FAB rather than [AddButton]; it needs the same
      // clearance above the phone navigation bar.
      floating: Padding(
        padding: EdgeInsets.only(bottom: floatingNavigationClearance(context)),
        child: FloatingActionButton.extended(
          heroTag: 'add-place',
          icon: const Icon(AppIcons.plus),
          label: Text(tr.commonPlace),
          onPressed: () => _edit(context, null),
        ),
      ),
      body: DataBuilder(
        collections: _collections,
        builder: (context, engine) {
          final places = engine.places;
          if (places.isEmpty) {
            return EmptyHint(
              icon: AppIcons.mapPin,
              color: FamioColors.of(context).strong(FamioSection.location),
              text: tr.placesNoPlacesYetHome,
            );
          }
          return ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              for (final p in places)
                ListTile(
                  leading: IconBlob(
                    AppIcons.mapPin,
                    color: FamioColors.of(
                      context,
                    ).strong(FamioSection.location),
                    background: FamioColors.of(
                      context,
                    ).tint(FamioSection.location),
                    size: 40,
                  ),
                  title: Text(p.name),
                  subtitle: Text(
                    tr.placesRadiusMRadiusNotify(
                      p.radius.round(),
                      p.notifyMemberIds.contains(me.id)
                          ? tr.placesYouNotified
                          : '',
                    ),
                  ),
                  onTap: () => _edit(context, p),
                ),
            ],
          );
        },
      ),
    );
  }

  static Future<void> _edit(BuildContext context, Place? place) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => PlaceEditor(place: place),
        ),
      );
}

class PlaceEditor extends StatefulWidget {
  const PlaceEditor({super.key, this.place});

  final Place? place;

  @override
  State<PlaceEditor> createState() => _PlaceEditorState();
}

class _PlaceEditorState extends State<PlaceEditor> {
  late final _name = TextEditingController(text: widget.place?.name);
  LatLng? _center;
  late double _radius = widget.place?.radius ?? Place.defaultRadius;
  late bool _notify;
  final _map = MapController();

  @override
  void initState() {
    super.initState();
    final p = widget.place;
    if (p != null) _center = LatLng(p.latitude, p.longitude);
    final me = AppScope.read(context).me!;
    _notify = p == null || p.notifyMemberIds.contains(me.id);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _useMyPosition() {
    final state = AppScope.read(context);
    final mine = state.engine!.memberLocations[state.me!.id];
    if (mine == null || !mine.hasPosition) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.placesNoCurrentPositionYours)));
      return;
    }
    final point = LatLng(mine.latitude!, mine.longitude!);
    setState(() => _center = point);
    _map.move(point, 16);
  }

  void _save() {
    final engine = AppScope.read(context).engine!;
    final me = AppScope.read(context).me!;
    final center = _center;
    if (_name.text.trim().isEmpty || center == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.placesPleaseEnterNameTap)));
      return;
    }
    final notify = {...?widget.place?.notifyMemberIds};
    _notify ? notify.add(me.id) : notify.remove(me.id);
    engine.savePlace(
      Place(
        id: widget.place?.id ?? newId(),
        name: _name.text.trim(),
        latitude: center.latitude,
        longitude: center.longitude,
        radius: _radius,
        notifyMemberIds: notify.toList(),
      ),
    );
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.commonDeleteName(widget.place!.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    AppScope.read(context).engine!.deletePlace(widget.place!.id);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.of(context).engine!;
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.location);
    final state = AppScope.of(context);
    final mine = engine.memberLocations[state.me!.id];
    final start =
        _center ??
        (mine != null && mine.hasPosition
            ? LatLng(mine.latitude!, mine.longitude!)
            : null);
    return SectionPage(
      section: FamioSection.location,
      title: widget.place == null ? tr.placesNewPlace : tr.placesEditPlace,
      actions: [
        ColorButton(label: tr.commonSave, color: accent, onPressed: _save),
      ],
      bodyPadding: EdgeInsets.zero,
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 8, 20, listBottomPadding(context)),
        children: [
          TextField(
            controller: _name,
            autofocus: widget.place == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: tr.commonName,
              hintText: tr.placesEGSchool,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            tr.placesTapMapSetCenter,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 320,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: FamilyMap(
                controller: _map,
                engine: engine,
                locations: const {},
                center: start,
                onTap: (point) => setState(() => _center = point),
                extra: [
                  if (_center != null)
                    CircleLayer(
                      circles: [
                        CircleMarker(
                          point: _center!,
                          radius: _radius,
                          useRadiusInMeter: true,
                          color: accent.withValues(alpha: 0.25),
                          borderColor: accent,
                          borderStrokeWidth: 3,
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(AppIcons.locate),
              label: Text(tr.placesMyPosition),
              onPressed: _useMyPosition,
            ),
          ),
          Text(tr.placesRadiusRadiusM(_radius.round())),
          Slider(
            // Logarithmic: fine steps for small, coarse for large places.
            value: math.log(_radius),
            min: math.log(Place.minRadius),
            max: math.log(Place.maxRadius),
            onChanged: (v) =>
                setState(() => _radius = (math.exp(v) / 10).round() * 10.0),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(AppIcons.bell),
            title: Text(tr.placesNotifyMe),
            subtitle: Text(tr.placesWhenSomeoneArrivesLeaves),
            value: _notify,
            onChanged: (v) => setState(() => _notify = v),
          ),
          if (widget.place != null) ...[
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(AppIcons.trash),
                label: Text(tr.placesDeletePlace),
                style: TextButton.styleFrom(foregroundColor: c.danger),
                onPressed: _delete,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// --- history ------------------------------------------------------------------
