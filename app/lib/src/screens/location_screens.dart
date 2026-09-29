import 'dart:async';
import 'dart:math' as math;

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../location/location_sharing.dart';
import '../widgets/data_builder.dart';
import '../widgets/form_dialog.dart';
import '../widgets/member_avatar.dart';
import '../widgets/password_reveal.dart';

const _collections = {
  Collections.places,
  Collections.memberLocations,
  'members',
};

/// Center of Germany, for an empty map.
const _fallbackCenter = LatLng(51.16, 10.45);

/// A position older than this is shown as outdated.
const _stale = Duration(minutes: 30);

/// Who is where: family map, places and the own sharing switch.
class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  final _map = MapController();

  void _focus(MemberLocation l) {
    if (!l.hasPosition) return;
    _map.move(LatLng(l.latitude!, l.longitude!), 15);
  }

  @override
  Widget build(BuildContext context) {
    return SectionPage(
      section: FamioSection.location,
      title: 'Wo ist wer?',
      subtitle: 'Standort der Familie',
      actions: [
        BubbleButton(
          icon: AppIcons.mapPin,
          tooltip: 'Orte',
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const PlacesScreen())),
        ),
      ],
      bodyPadding: EdgeInsets.zero,
      body: DataBuilder(
        collections: _collections,
        builder: (context, engine) {
          final locations = engine.memberLocations;
          final map = MinuteTicker(
            builder: (_) => ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: FamilyMap(
                controller: _map,
                engine: engine,
                locations: locations,
              ),
            ),
          );
          final list = MinuteTicker(
            builder: (_) => _MemberList(
              engine: engine,
              locations: locations,
              onFocus: _focus,
            ),
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 900) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 380, child: list),
                      const SizedBox(width: 16),
                      Expanded(child: map),
                    ],
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 5,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: map,
                    ),
                  ),
                  Expanded(flex: 5, child: list),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

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
  });

  final SyncEngine engine;
  final Map<String, MemberLocation> locations;
  final MapController? controller;

  /// Further layers above places and members (e.g. a route).
  final List<Widget> extra;
  final void Function(LatLng point)? onTap;

  /// Where to start instead of fitting everybody in.
  final LatLng? center;

  @override
  State<FamilyMap> createState() => _FamilyMapState();
}

class _FamilyMapState extends State<FamilyMap> {
  late final MapController _controller = widget.controller ?? MapController();

  /// Whether the camera already shows real positions; until then (e.g. the
  /// first sync is still running) it follows the data.
  var _fitted = false;

  List<LatLng> _points() {
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

  void _fit() {
    if (_fitted || widget.center != null) return;
    final points = _points();
    if (points.isEmpty) return;
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        if (points.length == 1) {
          _controller.move(points.single, 14);
        } else {
          _controller.fitCamera(
            CameraFit.coordinates(
              coordinates: points,
              padding: const EdgeInsets.all(56),
              maxZoom: 16,
            ),
          );
        }
      } catch (_) {
        _fitted = false; // Map not laid out yet; try with the next update.
      }
    });
  }

  @override
  void didUpdateWidget(FamilyMap old) {
    super.didUpdateWidget(old);
    _fit();
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
        onMapReady: _fit,
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

/// "Bei „Schule“ seit 8:02", "Unterwegs · vor 5 Min." …
String sharingLabel(MemberLocation? l, Place? place, {DateTime? now}) {
  now ??= DateTime.now();
  if (l == null) return 'Teilt keinen Standort';
  final time = DateFormat('HH:mm', 'de');
  switch (l.state) {
    case SharingState.paused:
      final until = l.pausedUntil;
      if (until == null) return 'Pausiert';
      return DateUtils.isSameDay(until, now)
          ? 'Pausiert bis ${time.format(until)} Uhr'
          : 'Pausiert bis ${DateFormat('E, HH:mm', 'de').format(until)} Uhr';
    case SharingState.denied:
      return 'Standortzugriff auf dem Handy fehlt';
    case SharingState.off:
      return 'Standort am Handy ausgeschaltet';
    case SharingState.scheduled:
      return 'Standortfreigabe ist nach Zeitplan gerade aus';
    case SharingState.active:
      final at = l.at;
      if (at == null) return 'Noch keine Position';
      if (_positionStale(l, now)) {
        final suffix = place == null ? '' : ': „${place.name}“';
        return 'Letzter Standort$suffix · ${ago(at, now: now)} · möglicherweise veraltet';
      }
      if (place != null) {
        return 'Bei „${place.name}“'
            '${l.placeSince == null ? '' : ' seit ${time.format(l.placeSince!)}'}'
            ' · zuletzt bestätigt ${ago(at, now: now)}';
      }
      return 'Unterwegs · zuletzt bestätigt ${ago(at, now: now)}';
  }
}

/// A heartbeat only proves that the phone reached the server. It must not
/// make an older measured coordinate appear current on the family map.
bool _positionStale(MemberLocation l, DateTime now) =>
    l.at == null || now.difference(l.at!) >= _stale;

String ago(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 2) return 'gerade eben';
  if (d.inMinutes < 60) return 'vor ${d.inMinutes} Min.';
  if (d.inHours < 24) return 'vor ${d.inHours} Std.';
  return DateFormat('d.M., HH:mm', 'de').format(t);
}

String scheduleLabel(LocationSchedule? schedule) {
  if (schedule == null) return 'Immer teilen';
  const names = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
  final days = schedule.weekdays.map((day) => names[day - 1]).join(', ');
  String clock(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
  return '$days · ${clock(schedule.startMinute)}–${clock(schedule.endMinute)} Uhr';
}

/// Configures a privacy-preserving recurring sharing window. The server
/// checks the parents' code and drops positions outside the selected times.
Future<LocationSchedule?> showLocationScheduleDialog(
  BuildContext context, {
  LocationSchedule? initial,
}) async {
  final code = TextEditingController();
  final days = {...?initial?.weekdays};
  var start = TimeOfDay(
    hour: (initial?.startMinute ?? 7 * 60) ~/ 60,
    minute: (initial?.startMinute ?? 7 * 60) % 60,
  );
  var end = TimeOfDay(
    hour: (initial?.endMinute ?? 18 * 60) ~/ 60,
    minute: (initial?.endMinute ?? 18 * 60) % 60,
  );
  var busy = false;
  String? error;
  LocationSchedule? result = initial;
  final labels = const ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> save(LocationSchedule? schedule) async {
          setState(() {
            busy = true;
            error = null;
          });
          try {
            result = await AppScope.read(context).engine!.api
                .setLocationSchedule(code: code.text, schedule: schedule);
            if (context.mounted) Navigator.pop(context);
          } on ApiError catch (e) {
            setState(() => error = e.message);
          } finally {
            if (context.mounted) setState(() => busy = false);
          }
        }

        final startMinute = start.hour * 60 + start.minute;
        final endMinute = end.hour * 60 + end.minute;
        final valid = days.isNotEmpty && startMinute != endMinute;
        return AlertDialog(
          scrollable: true,
          title: const Text('Standort-Zeitplan'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Außerhalb dieses Zeitfensters speichert und zeigt Famio '
                  'keine Position von diesem Handy. Nach Beginn zeigt die '
                  'Karte erst wieder einen neu gemeldeten Standort.',
                ),
                const SizedBox(height: 16),
                const Text('Tage'),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var day = 1; day <= 7; day++)
                      FilterChip(
                        label: Text(labels[day - 1]),
                        selected: days.contains(day),
                        onSelected: busy
                            ? null
                            : (selected) => setState(() {
                                if (selected) {
                                  days.add(day);
                                } else {
                                  days.remove(day);
                                }
                              }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(AppIcons.clock),
                      label: Text('Von ${start.format(context)}'),
                      onPressed: busy
                          ? null
                          : () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: start,
                              );
                              if (picked != null) {
                                setState(() => start = picked);
                              }
                            },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(AppIcons.clock),
                      label: Text('Bis ${end.format(context)}'),
                      onPressed: busy
                          ? null
                          : () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: end,
                              );
                              if (picked != null) {
                                setState(() => end = picked);
                              }
                            },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                PasswordReveal(
                  builder: (_, obscure, toggle) => TextField(
                    controller: code,
                    autofocus: true,
                    obscureText: obscure,
                    contextMenuBuilder: PasswordReveal.contextMenu,
                    decoration: InputDecoration(
                      labelText: 'Eltern-Code',
                      prefixIcon: const Icon(AppIcons.lockKey),
                      suffixIcon: toggle,
                    ),
                  ),
                ),
                if (!valid)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Mindestens einen Tag und unterschiedliche Zeiten wählen.',
                    ),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            if (initial != null)
              TextButton(
                onPressed: busy ? null : () => save(null),
                child: const Text('Zeitplan entfernen'),
              ),
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: busy || !valid
                  ? null
                  : () => save(
                      LocationSchedule(
                        weekdays: days.toList()..sort(),
                        startMinute: startMinute,
                        endMinute: endMinute,
                      ),
                    ),
              child: const Text('Speichern'),
            ),
          ],
        );
      },
    ),
  );
  code.dispose();
  return result;
}

class _MemberList extends StatelessWidget {
  const _MemberList({
    required this.engine,
    required this.locations,
    required this.onFocus,
  });

  final SyncEngine engine;
  final Map<String, MemberLocation> locations;
  final void Function(MemberLocation) onFocus;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final me = state.me!;
    final theme = Theme.of(context);
    final members = [...engine.members]
      ..sort((a, b) {
        // Me first, then who shares, then by name.
        if (a.id == me.id) return -1;
        if (b.id == me.id) return 1;
        final shares =
            (locations.containsKey(b.id) ? 1 : 0) -
            (locations.containsKey(a.id) ? 1 : 0);
        return shares != 0 ? shares : a.displayName.compareTo(b.displayName);
      });
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 12, 16, listBottomPadding(context)),
      children: [
        MySharingCard(
          location: locations[me.id],
          place: engine.place(locations[me.id]?.placeId),
        ),
        const SizedBox(height: 8),
        for (final m in members)
          _MemberTile(
            member: m,
            location: locations[m.id],
            place: engine.place(locations[m.id]?.placeId),
            isMe: m.id == me.id,
            canManage: me.isAdmin,
            onTap: locations[m.id] == null
                ? null
                : () => onFocus(locations[m.id]!),
          ),
        if (engine.places.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Tipp: Lege Orte wie Zuhause oder Schule an (oben rechts) – '
              'dann meldet Famio, wer angekommen oder losgegangen ist.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.location,
    required this.place,
    required this.isMe,
    required this.canManage,
    this.onTap,
  });

  final FamilyMember member;
  final MemberLocation? location;
  final Place? place;
  final bool isMe;
  final bool canManage;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final l = location;
    final warn =
        l != null &&
        (l.state == SharingState.denied ||
            l.state == SharingState.off ||
            (l.state == SharingState.active &&
                _positionStale(l, DateTime.now())));
    final canHistory = (isMe || canManage) && l != null;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: MemberAvatar(member, radius: 20),
      title: Text(isMe ? '${member.displayName} (ich)' : member.displayName),
      subtitle: Text(
        [
          sharingLabel(l, place),
          if (l?.battery != null && l!.state != SharingState.paused)
            '${l.battery} % Akku',
        ].join(' · '),
        style: warn ? TextStyle(color: c.danger) : null,
      ),
      onTap: onTap,
      trailing: canHistory || canManage
          ? PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'history':
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => LocationHistoryScreen(member: member),
                      ),
                    );
                  case 'pause':
                    await showPauseDialog(context, member: member);
                  case 'resume':
                    await _resume(context);
                }
              },
              itemBuilder: (_) => [
                if (canHistory)
                  const PopupMenuItem(value: 'history', child: Text('Verlauf')),
                if (canManage && l != null && l.state != SharingState.paused)
                  const PopupMenuItem(value: 'pause', child: Text('Pausieren')),
                if (canManage && l?.state == SharingState.paused)
                  const PopupMenuItem(
                    value: 'resume',
                    child: Text('Fortsetzen'),
                  ),
              ],
            )
          : null,
    );
  }

  Future<void> _resume(BuildContext context) async {
    final state = AppScope.read(context);
    try {
      await state.engine!.api.resumeLocation(memberId: member.id);
      if (isMe) await _refreshService(state);
      unawaited(state.engine!.sync());
    } on ApiError catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }
}

Future<void> _refreshService(AppState state) => LocationSharing.refresh(
  serverUrl: state.serverUrl!,
  certificatePin: state.certificatePin,
  device: AppState.deviceName,
  places: state.engine!.places,
);

/// Asks for the parents' code and how long, then pauses [member].
/// Returns whether it was paused.
Future<bool> showPauseDialog(
  BuildContext context, {
  required FamilyMember member,
  bool stopOnThisDevice = false,
}) async {
  final state = AppScope.read(context);
  final api = state.engine!.api;
  final code = TextEditingController();
  Duration? duration = const Duration(hours: 1);
  var done = false;
  final now = DateTime.now();
  final morning = DateTime(now.year, now.month, now.day + 1, 7);
  final choices = <String, Duration?>{
    '1 Stunde': const Duration(hours: 1),
    '3 Stunden': const Duration(hours: 3),
    'Bis morgen früh': morning.difference(now),
    'Bis zum Fortsetzen': null,
  };
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => FormDialog(
        title: stopOnThisDevice
            ? 'Standortfreigabe beenden'
            : 'Standort von ${member.displayName} pausieren',
        submitLabel: stopOnThisDevice ? 'Beenden' : 'Pausieren',
        controllers: [code],
        fields: [
          Text(
            stopOnThisDevice
                ? 'Auf diesem Handy wird der Standort nicht mehr geteilt. '
                      'Dafür braucht es den Eltern-Code.'
                : 'Dafür braucht es den Eltern-Code.',
          ),
          if (!stopOnThisDevice)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final MapEntry(key: label, value: d) in choices.entries)
                  ChoiceChip(
                    label: Text(label),
                    selected: duration == d,
                    onSelected: (_) => setState(() => duration = d),
                  ),
              ],
            ),
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: code,
              autofocus: true,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(
                suffixIcon: toggle,
                labelText: 'Eltern-Code',
                prefixIcon: Icon(AppIcons.lockKey),
              ),
            ),
          ),
        ],
        onSubmit: () async {
          await api.pauseLocation(
            code: code.text,
            memberId: member.id,
            duration: stopOnThisDevice ? null : duration,
          );
          if (stopOnThisDevice) await LocationSharing.disable(api: api);
          done = true;
          // Show the new state at once instead of with the next sync.
          unawaited(state.engine?.sync());
        },
      ),
    ),
  );
  return done;
}

/// This phone's sharing switch with everything that may stop it working.
class MySharingCard extends StatefulWidget {
  const MySharingCard({super.key, this.location, this.place});

  /// The own sharing status as the family sees it (from the server).
  final MemberLocation? location;
  final Place? place;

  @override
  State<MySharingCard> createState() => _MySharingCardState();
}

class _MySharingCardState extends State<MySharingCard>
    with WidgetsBindingObserver {
  DeviceSharingStatus? _device;
  LocationSchedule? _schedule;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from the system settings: the permissions may have changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (!LocationSharing.supported) return;
    final status = await LocationSharing.status();
    if (!mounted) return;
    final api = AppScope.read(context).engine?.api;
    LocationSchedule? schedule = _schedule;
    try {
      schedule = await api?.locationSchedule();
    } on ApiError {
      // The device diagnosis remains useful when the server is offline.
    }
    if (mounted) {
      setState(() {
        _device = status;
        _schedule = schedule;
      });
    }
  }

  Future<void> _editSchedule() async {
    final schedule = await showLocationScheduleDialog(
      context,
      initial: _schedule,
    );
    if (!mounted) return;
    setState(() => _schedule = schedule);
    unawaited(AppScope.read(context).engine?.sync());
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on ApiError catch (e) {
      _snack(e.message);
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _enable() => _run(() async {
    final state = AppScope.read(context);
    var status = await LocationSharing.requestPermission();
    if (status.permission == LocationPermission.none) {
      _snack(
        'Ohne Standortzugriff kann Famio nichts teilen. Du kannst ihn in den '
        'App-Einstellungen erlauben.',
      );
      return;
    }
    await LocationSharing.enable(
      api: state.engine!.api,
      serverUrl: state.serverUrl!,
      certificatePin: state.certificatePin,
      device: AppState.deviceName,
      places: state.engine!.places,
    );
    status = await LocationSharing.status();
    if (!mounted) return;
    if (status.permission == LocationPermission.foreground) {
      await _askAlways();
    }
  });

  Future<void> _askAlways() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Standort auch im Hintergrund teilen?'),
        content: const Text(
          'Damit Famio deinen Standort auch bei geschlossener App zuverlässig '
          'aktualisieren kann, braucht es den Standortzugriff „Immer '
          'zulassen“. Android öffnet dafür gleich seine Einstellungen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Später'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Freigabe aktivieren'),
          ),
        ],
      ),
    );
    if (ok == true) await LocationSharing.requestPermission(background: true);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.location);
    if (!LocationSharing.supported) {
      return SoftCard(
        color: c.tint(FamioSection.location),
        padding: const EdgeInsets.all(16),
        child: Text(
          'Den eigenen Standort teilt man mit der Famio-App auf dem Handy '
          '(Android oder iPhone). Hier siehst du, wo die anderen sind.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    final device = _device;
    if (device == null) return const SizedBox(height: 8);
    final me = state.me!;
    final mine = widget.location;

    if (!device.enabled) {
      return SoftCard(
        color: c.tint(FamioSection.location),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Meinen Standort teilen', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Deine Familie sieht auf der Karte, wo du bist, und bekommt '
              'Bescheid, wenn du an einem Ort ankommst. Positionen werden '
              'nach 7 Tagen gelöscht. Pausieren geht nur mit dem Eltern-Code.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ColorButton(
              label: 'Standort teilen',
              icon: AppIcons.locate,
              color: accent,
              onPressed: _busy ? null : _enable,
            ),
          ],
        ),
      );
    }

    final paused = mine?.state == SharingState.paused;
    final scheduled = mine?.state == SharingState.scheduled;
    final backgroundLimited =
        device.permission == LocationPermission.foreground;
    final hints = <(String, Future<void> Function())>[
      if (device.permission == LocationPermission.none)
        (
          'Standortzugriff fehlt – antippen zum Erlauben',
          () async {
            final s = await LocationSharing.requestPermission();
            if (s.permission == LocationPermission.none) {
              await LocationSharing.openAppSettings();
            } else {
              await _refreshService(state);
            }
          },
        ),
      if (backgroundLimited)
        (
          'Hintergrundortung ist nicht aktiv – der Standort wird nur bei '
              'geöffneter App zuverlässig aktualisiert',
          _askAlways,
        ),
      if (!device.locationOn)
        ('Standort ist am Handy ausgeschaltet', () async {}),
      if (!device.batteryUnrestricted)
        (
          'Akku-Optimierung kann die Freigabe stoppen – antippen',
          LocationSharing.openBatterySettings,
        ),
      if (!device.notifications)
        ('Benachrichtigungen sind aus', LocationSharing.openAppSettings),
    ];
    return SoftCard(
      color: c.tint(FamioSection.location),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                paused || scheduled ? AppIcons.pause : AppIcons.locate,
                color: accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  paused
                      ? 'Freigabe pausiert'
                      : scheduled
                      ? 'Freigabe nach Zeitplan aus'
                      : backgroundLimited
                      ? 'Standortfreigabe eingeschränkt'
                      : 'Du teilst deinen Standort',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            sharingLabel(mine, widget.place),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Zeitplan: ${scheduleLabel(_schedule)}',
            style: theme.textTheme.bodySmall,
          ),
          for (final (text, action) in hints)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: InkWell(
                onTap: () => _run(action),
                child: Row(
                  children: [
                    Icon(AppIcons.warningCircle, size: 16, color: c.danger),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        text,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: c.danger,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          _LocationDiagnostics(location: mine, device: device),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (paused)
                FilledButton.tonalIcon(
                  icon: const Icon(AppIcons.play),
                  label: const Text('Fortsetzen'),
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await state.engine!.api.resumeLocation();
                          await _refreshService(state);
                          unawaited(state.engine!.sync());
                        }),
                )
              else
                FilledButton.tonalIcon(
                  icon: const Icon(AppIcons.pause),
                  label: const Text('Pausieren'),
                  onPressed: _busy
                      ? null
                      : () => showPauseDialog(context, member: me),
                ),
              TextButton.icon(
                icon: const Icon(AppIcons.clock),
                label: const Text('Zeitplan'),
                onPressed: _busy ? null : _editSchedule,
              ),
              TextButton.icon(
                icon: const Icon(AppIcons.stop),
                label: const Text('Beenden'),
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await showPauseDialog(
                          context,
                          member: me,
                          stopOnThisDevice: true,
                        );
                      }),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LocationDiagnostics extends StatelessWidget {
  const _LocationDiagnostics({required this.location, required this.device});

  final MemberLocation? location;
  final DeviceSharingStatus device;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final permission = switch (device.permission) {
      LocationPermission.always => 'Immer erlaubt',
      LocationPermission.foreground => 'Nur bei geöffneter App',
      LocationPermission.none => 'Nicht erlaubt',
    };
    final rows = <String>[
      'Berechtigung: $permission',
      'Letzter GPS-Fix: ${_when(device.lastFixAt, now)}',
      'Letzter erfolgreicher Positions-Upload: '
          '${_when(device.lastSuccessfulUploadAt, now)}',
      'Letzte Serverantwort: ${_when(device.lastServerResponseAt, now)}'
          '${device.lastServerStatus == null ? '' : ' (${device.lastServerStatus})'}',
      if (device.lastErrorAt != null)
        'Letzter Übertragungsfehler: ${_when(device.lastErrorAt, now)}'
            '${device.lastError == null ? '' : ' (${device.lastError})'}',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Diagnose', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          for (final row in rows) Text(row, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  String _when(DateTime? at, DateTime now) =>
      at == null ? 'noch nie' : ago(at, now: now);
}

// --- places -------------------------------------------------------------------

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
        padding: EdgeInsets.only(
          bottom: MediaQuery.sizeOf(context).width < 720 ? 84 : 0,
        ),
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

/// Keeps a widget rebuilding every minute ("vor 3 Min.").
class MinuteTicker extends StatefulWidget {
  const MinuteTicker({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  State<MinuteTicker> createState() => _MinuteTickerState();
}

class _MinuteTickerState extends State<MinuteTicker> {
  late final Timer _timer = Timer.periodic(
    const Duration(minutes: 1),
    (_) => setState(() {}),
  );

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _timer; // Starts the timer.
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
