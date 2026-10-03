part of '../location_screens.dart';

class PlacesScreen extends StatelessWidget {
  const PlacesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final me = AppScope.of(context).me!;
    return SectionPage(
      section: FamioSection.location,
      title: 'Orte',
      subtitle: 'Ankommen und Losgehen melden',
      // This is an extended FAB rather than [AddButton]; it needs the same
      // clearance above the phone navigation bar.
      floating: Padding(
        padding: EdgeInsets.only(bottom: floatingNavigationClearance(context)),
        child: FloatingActionButton.extended(
          heroTag: 'add-place',
          icon: const Icon(AppIcons.plus),
          label: const Text('Ort'),
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
              text:
                  'Noch keine Orte. Zuhause, Schule, Kita, Sportverein: '
                  'Famio meldet, wer angekommen oder losgegangen ist.',
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
                    '${p.radius.round()} m Umkreis'
                    '${p.notifyMemberIds.contains(me.id) ? ' · du wirst benachrichtigt' : ''}',
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Keine aktuelle Position von dir – tippe stattdessen auf die Karte.',
          ),
        ),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bitte einen Namen eingeben und auf die Karte tippen'),
        ),
      );
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
        title: Text('„${widget.place!.name}“ löschen?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
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
      title: widget.place == null ? 'Neuer Ort' : 'Ort bearbeiten',
      actions: [
        ColorButton(label: 'Speichern', color: accent, onPressed: _save),
      ],
      bodyPadding: EdgeInsets.zero,
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 8, 20, listBottomPadding(context)),
        children: [
          TextField(
            controller: _name,
            autofocus: widget.place == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'z. B. Schule',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Auf die Karte tippen, um die Mitte festzulegen.',
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
              label: const Text('Meine Position'),
              onPressed: _useMyPosition,
            ),
          ),
          Text('Umkreis: ${_radius.round()} m'),
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
            title: const Text('Mich benachrichtigen'),
            subtitle: const Text('Wenn jemand ankommt oder losgeht'),
            value: _notify,
            onChanged: (v) => setState(() => _notify = v),
          ),
          if (widget.place != null) ...[
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(AppIcons.trash),
                label: const Text('Ort löschen'),
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
