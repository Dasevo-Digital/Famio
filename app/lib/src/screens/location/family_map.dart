part of '../location_screens.dart';

/// OpenStreetMap with places and family members.
class FamilyMap extends StatefulWidget {
  const FamilyMap({
    super.key,
    required this.engine,
    required this.locations,
    this.controller,
    this.extra = const [],
    this.onTap,
    this.center,
    this.focus,
    this.onShowAll,
  });

  final SyncEngine engine;
  final Map<String, MemberLocation> locations;
  final MapController? controller;

  /// Further layers above places and members (e.g. a route).
  final List<Widget> extra;
  final void Function(LatLng point)? onTap;

  /// Where to start instead of fitting everybody in; the camera then stays
  /// where the user puts it.
  final LatLng? center;

  /// The member the camera follows instead of everybody.
  final String? focus;

  /// Called by the "follow again" button, e.g. to drop [focus].
  final VoidCallback? onShowAll;

  @override
  State<FamilyMap> createState() => _FamilyMapState();
}

class _FamilyMapState extends State<FamilyMap> {
  late final MapController _controller = widget.controller ?? MapController();

  /// The camera follows the positions (everybody or [FamilyMap.focus]) until
  /// the user moves the map. Previously it was fitted once, so somebody who
  /// moved while the map stayed open walked out of the picture.
  var _following = true;

  /// What the camera was last moved to, so updates without movement (and
  /// the minute ticker) leave it alone.
  List<LatLng>? _shownTargets;

  List<LatLng> _targets() {
    final focused = widget.locations[widget.focus];
    if (focused != null && focused.hasPosition) {
      return [LatLng(focused.latitude!, focused.longitude!)];
    }
    final members = {for (final m in widget.engine.members) m.id};
    final shown = [
      for (final l in widget.locations.values)
        if (l.hasPosition && members.contains(l.memberId))
          LatLng(l.latitude!, l.longitude!),
    ];
    return shown.isNotEmpty
        ? shown
        : [
            for (final p in widget.engine.places)
              LatLng(p.latitude, p.longitude),
          ];
  }

  void _follow() {
    if (!_following || widget.center != null) return;
    final targets = _targets();
    if (targets.isEmpty || listEquals(targets, _shownTargets)) return;
    final first = _shownTargets == null;
    _shownTargets = targets;
    final focused = widget.focus != null && targets.length == 1;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        if (targets.length == 1) {
          // A followed member keeps the zoom the user chose.
          _controller.move(
            targets.single,
            focused && !first ? _controller.camera.zoom : (focused ? 15 : 14),
          );
        } else {
          _controller.fitCamera(
            CameraFit.coordinates(
              coordinates: targets,
              padding: const EdgeInsets.all(56),
              maxZoom: 16,
            ),
          );
        }
      } catch (_) {
        _shownTargets = null; // Not laid out yet; try with the next update.
      }
    });
  }

  void _followAgain() {
    setState(() {
      _following = true;
      _shownTargets = null;
    });
    widget.onShowAll?.call();
    _follow();
  }

  @override
  void didUpdateWidget(FamilyMap old) {
    super.didUpdateWidget(old);
    if (widget.focus != old.focus) {
      // Tapping a member (again) follows them, also after a manual move.
      _following = true;
      _shownTargets = null;
    }
    _follow();
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.location);
    final engine = widget.engine;
    final locations = widget.locations;
    final center = widget.center;
    final places = engine.places;
    final members = {for (final m in engine.members) m.id: m};
    final shown = [
      for (final l in locations.values)
        if (l.hasPosition && members.containsKey(l.memberId)) l,
    ];
    final points = [
      for (final l in shown) LatLng(l.latitude!, l.longitude!),
      if (shown.isEmpty)
        for (final p in places) LatLng(p.latitude, p.longitude),
    ];
    final now = DateTime.now();
    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: center ?? points.firstOrNull ?? _fallbackCenter,
        initialZoom: center != null ? 15 : (points.isEmpty ? 5.5 : 14),
        initialCameraFit: center == null && points.length > 1
            ? CameraFit.coordinates(
                coordinates: points,
                padding: const EdgeInsets.all(56),
                maxZoom: 16,
              )
            : null,
        onTap: widget.onTap == null ? null : (_, point) => widget.onTap!(point),
        onMapReady: _follow,
        onPositionChanged: (_, hasGesture) {
          if (hasGesture && _following && center == null) {
            setState(() => _following = false);
          }
        },
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        tileLayer(context),
        CircleLayer(
          circles: [
            for (final p in places)
              CircleMarker(
                point: LatLng(p.latitude, p.longitude),
                radius: p.radius,
                useRadiusInMeter: true,
                color: accent.withValues(alpha: 0.12),
                borderColor: accent.withValues(alpha: 0.7),
                borderStrokeWidth: 2,
              ),
          ],
        ),
        MarkerLayer(
          markers: [
            for (final p in places)
              Marker(
                point: LatLng(p.latitude, p.longitude),
                width: 140,
                // Below the point, not hidden behind a member's avatar.
                height: 96,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: c.surface.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
              ),
          ],
        ),
        ...widget.extra,
        MarkerLayer(
          markers: [
            for (final l in shown)
              Marker(
                point: LatLng(l.latitude!, l.longitude!),
                width: 46,
                height: 46,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Opacity(
                      opacity:
                          l.state == SharingState.active &&
                              !_positionStale(l, now)
                          ? 1
                          : 0.5,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: c.softShadow,
                        ),
                        child: MemberAvatar(members[l.memberId]!, radius: 20),
                      ),
                    ),
                    if (_positionStale(l, now))
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: c.surface,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            AppIcons.warningCircle,
                            size: 15,
                            color: c.danger,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
        attribution(context),
        if (!_following && center == null)
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: BubbleButton(
                icon: AppIcons.locate,
                tooltip: 'Alle zeigen und wieder mitführen',
                onPressed: _followAgain,
              ),
            ),
          ),
      ],
    );
  }
}

const _osmTiles = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// Map tiles from the server set by the admins, else OpenStreetMap.
Widget tileLayer(BuildContext context) => TileLayer(
  urlTemplate: AppScope.of(context).mapTileUrl ?? _osmTiles,
  userAgentPackageName: 'de.status403.famio',
  maxZoom: 19,
);

/// Small source note in the map's corner, as the tile licence asks for.
/// Tapping it opens the map data's copyright page.
Widget attribution(BuildContext context) {
  final custom = AppScope.of(context).mapTileUrl;
  final host = custom == null
      ? null
      : Uri.tryParse(custom.replaceAll(RegExp(r'[{}]'), ''))?.host;
  final c = FamioColors.of(context);
  return Align(
    alignment: Alignment.bottomRight,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Material(
        color: c.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: custom == null
              ? () => launchUrl(
                  Uri.parse('https://www.openstreetmap.org/copyright'),
                  mode: LaunchMode.externalApplication,
                )
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              custom == null
                  ? '© OpenStreetMap'
                  : 'Karte: ${host == null || host.isEmpty ? custom : host}',
              style: TextStyle(fontSize: 11, color: c.inkSoft),
            ),
          ),
        ),
      ),
    ),
  );
}
