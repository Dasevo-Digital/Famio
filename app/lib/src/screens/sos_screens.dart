import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../sos/sos_controller.dart';
import '../sos/sos_device.dart';
import '../widgets/data_builder.dart';
import 'location_screens.dart' show tileLayer;

const _sosRed = Color(0xFFD32F2F);

/// The emergency button: held for [hold], then the alarm starts. A tap only
/// explains that, so a pocket or a toddler does not raise it.
class SosHoldButton extends StatefulWidget {
  const SosHoldButton({super.key, this.large = false});

  /// The big round button (children's start page); else a compact one.
  final bool large;

  static const hold = Duration(seconds: 3);

  @override
  State<SosHoldButton> createState() => _SosHoldButtonState();
}

class _SosHoldButtonState extends State<SosHoldButton>
    with SingleTickerProviderStateMixin {
  late final _progress = AnimationController(
    vsync: this,
    duration: SosHoldButton.hold,
  )..addStatusListener(_done);

  void _done(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _progress.reset();
    HapticFeedback.heavyImpact();
    openSos(context);
  }

  Offset? _downAt;

  void _release({bool tap = false}) {
    if (_downAt == null) return;
    _downAt = null;
    if (_progress.value >= 1 || !_progress.isAnimating) return;
    final short = _progress.value < 0.3;
    _progress.reverse();
    if (tap && short) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Für einen Notruf 3 Sekunden gedrückt halten'),
          ),
        );
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.large ? 168.0 : 56.0;
    return Semantics(
      button: true,
      label: 'Notfallknopf, drei Sekunden gedrückt halten',
      // Raw pointer events: no other gesture (scrolling, a card's long
      // press) can take the hold away; moving the finger cancels it.
      child: Listener(
        onPointerDown: (e) {
          _downAt = e.position;
          _progress.forward(from: 0);
        },
        onPointerMove: (e) {
          if ((e.position - (_downAt ?? e.position)).distance > 24) _release();
        },
        onPointerUp: (_) => _release(tap: true),
        onPointerCancel: (_) => _release(),
        child: AnimatedBuilder(
          animation: _progress,
          builder: (context, _) => SizedBox.square(
            dimension: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.square(
                  dimension: size,
                  child: CircularProgressIndicator(
                    value: _progress.value,
                    strokeWidth: widget.large ? 10 : 4,
                    color: Colors.white,
                    backgroundColor: _sosRed.withValues(alpha: 0.25),
                  ),
                ),
                Container(
                  width: size - (widget.large ? 20 : 8),
                  height: size - (widget.large ? 20 : 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color.lerp(
                      _sosRed,
                      const Color(0xFF8E0000),
                      _progress.value,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _sosRed.withValues(alpha: 0.4),
                        blurRadius: widget.large ? 24 : 8,
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'SOS',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: widget.large ? 44 : 16,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The card on the children's start page.
class SosCard extends StatelessWidget {
  const SosCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SoftCard(
      color: _sosRed.withValues(alpha: 0.08),
      child: Row(
        children: [
          const SosHoldButton(large: true),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Notfall?', style: theme.textTheme.titleLarge),
                const SizedBox(height: 6),
                const Text(
                  'Halte den roten Knopf 3 Sekunden lang. Deine Eltern '
                  'bekommen sofort einen Alarm und sehen, wo du bist.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Starts the alarm (or shows the running one) for this member.
Future<void> openSos(BuildContext context) async {
  final engine = AppScope.read(context).engine;
  if (engine == null) return;
  final controller = SosController.current ??= SosController(engine);
  final fresh =
      controller.step == SosStep.starting && controller.alertId == null;
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => SosActiveScreen(controller: controller, start: fresh),
    ),
  );
}

/// The screen of the member who pressed the button.
class SosActiveScreen extends StatefulWidget {
  const SosActiveScreen({
    super.key,
    required this.controller,
    this.start = false,
  });

  final SosController controller;

  /// Trigger now (else it is the running alarm, reopened).
  final bool start;

  @override
  State<SosActiveScreen> createState() => _SosActiveScreenState();
}

class _SosActiveScreenState extends State<SosActiveScreen> {
  SosController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    if (widget.start) _c.trigger();
  }

  Future<void> _resolve() async {
    final navigator = Navigator.of(context);
    try {
      await _c.resolve();
    } on ApiError {
      // Offline: at least the siren and the updates stop here.
    }
    if (SosController.current == _c) {
      SosController.current = null;
      _c.dispose();
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DataBuilder(
      collections: const {Collections.sosAlerts, 'members'},
      builder: (context, engine) => ListenableBuilder(
        listenable: _c,
        builder: (context, _) {
          final id = _c.alertId;
          final record = id == null
              ? null
              : engine.record(Collections.sosAlerts, id);
          final alert = record == null ? null : SosAlert.fromRecord(record);
          final coming = alert?.state == SosState.coming
              ? engine.member(alert!.comingBy)?.displayName
              : null;
          final (title, text) = switch (_c.step) {
            SosStep.starting => ('Alarm wird gesendet …', 'Einen Moment.'),
            SosStep.sent when coming != null => (
              '$coming kommt!',
              '$coming hat deinen Alarm gesehen und ist unterwegs.',
            ),
            SosStep.sent => (
              'Alarm gesendet',
              'Deine Familie wurde alarmiert und sieht, wo du bist.',
            ),
            SosStep.offline => (
              'Kein Internet',
              _c.smsSent
                  ? 'Deine Eltern haben eine SMS mit deinem Standort '
                        'bekommen.'
                  : 'Der Alarm konnte nicht gesendet werden. Ruf an!',
            ),
            SosStep.failed => (
              'Alarm nicht gesendet',
              'Der Server hat den Alarm nicht angenommen. Ruf an!',
            ),
          };
          return Scaffold(
            backgroundColor: coming != null ? const Color(0xFF2E7D32) : _sosRed,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Spacer(),
                    Icon(
                      coming != null ? AppIcons.check : AppIcons.siren,
                      size: 96,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      text,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    if (_c.callNumber != null)
                      _BigButton(
                        icon: AppIcons.phoneCall,
                        label: 'Anrufen',
                        onPressed: () => SosDevice.call(_c.callNumber!),
                      ),
                    if (_c.sirenOn)
                      _BigButton(
                        icon: AppIcons.bellOff,
                        label: 'Sirene aus',
                        onPressed: () => _c.siren(false),
                      )
                    else
                      _BigButton(
                        icon: AppIcons.siren,
                        label: 'Sirene an',
                        onPressed: () => _c.siren(true),
                      ),
                    _BigButton(
                      icon: AppIcons.shieldCheck,
                      label: 'Ich bin sicher – Alarm beenden',
                      onPressed: _resolve,
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        'Zurück zu Famio (Alarm läuft weiter)',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      icon: Icon(icon),
      label: Text(label),
      onPressed: onPressed,
    ),
  );
}

/// Open alarms at the top of the app: the own one, or a family member's
/// for the adults.
class SosBanner extends StatelessWidget {
  const SosBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      collections: const {Collections.sosAlerts, 'members'},
      builder: (context, engine) {
        final open =
            [
                for (final r in engine.records(Collections.sosAlerts))
                  SosAlert.fromRecord(r),
              ].where((a) => a.open).toList()
              ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
        if (open.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final a in open.take(2))
              Material(
                color: a.state == SosState.coming
                    ? const Color(0xFFEF6C00)
                    : _sosRed,
                child: SafeArea(
                  bottom: false,
                  child: ListTile(
                    textColor: Colors.white,
                    iconColor: Colors.white,
                    leading: const Icon(AppIcons.siren),
                    title: Text(
                      a.memberId == engine.memberId
                          ? 'Dein Notruf läuft'
                          : 'SOS von ${engine.member(a.memberId)?.displayName ?? 'Jemand'}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      [
                        'seit ${DateFormat('HH:mm').format(a.startedAt)} Uhr',
                        if (a.state == SosState.coming)
                          '${engine.member(a.comingBy)?.displayName ?? 'Jemand'} kommt',
                      ].join(' · '),
                    ),
                    trailing: const Icon(AppIcons.caretRight),
                    onTap: () => a.memberId == engine.memberId
                        ? openSos(context)
                        : Navigator.of(context, rootNavigator: true).push(
                            MaterialPageRoute<void>(
                              builder: (_) => SosAlertScreen(alertId: a.id),
                            ),
                          ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// An adult's view of someone's alarm: where, since when, and "Ich komme".
class SosAlertScreen extends StatelessWidget {
  const SosAlertScreen({super.key, required this.alertId});

  final String alertId;

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      collections: const {
        Collections.sosAlerts,
        Collections.sosSettings,
        'members',
      },
      builder: (context, engine) {
        final record = engine.record(Collections.sosAlerts, alertId);
        if (record == null) {
          return const Scaffold(body: Center(child: Text('Nicht gefunden')));
        }
        final a = SosAlert.fromRecord(record);
        final name = engine.member(a.memberId)?.displayName ?? 'Jemand';
        final phone = SosSettings.fromRecord(
          engine.record(Collections.sosSettings, SosSettings.recordId),
        ).phones[a.memberId];
        final time = DateFormat('HH:mm');
        final messenger = ScaffoldMessenger.of(context);
        Future<void> run(Future<void> Function() action) async {
          try {
            await action();
          } on ApiError catch (e) {
            messenger.showSnackBar(SnackBar(content: Text(e.message)));
          }
        }

        final point = a.hasPosition ? LatLng(a.latitude!, a.longitude!) : null;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: a.open ? _sosRed : null,
            foregroundColor: a.open ? Colors.white : null,
            title: Text('SOS von $name'),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(switch (a.state) {
                SosState.active => 'Noch niemand hat reagiert.',
                SosState.coming =>
                  '${engine.member(a.comingBy)?.displayName ?? 'Jemand'} ist unterwegs.',
                SosState.resolved =>
                  'Beendet um ${time.format(a.resolvedAt ?? a.startedAt)} Uhr '
                      'von ${engine.member(a.resolvedBy)?.displayName ?? 'jemandem'}.',
              }, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                [
                  'Ausgelöst um ${time.format(a.startedAt)} Uhr',
                  if (a.positionAt != null)
                    'Standort von ${time.format(a.positionAt!)} Uhr'
                        '${a.accuracy == null ? '' : ' (± ${a.accuracy!.round()} m)'}',
                  if (a.battery != null) 'Akku ${a.battery} %',
                ].join(' · '),
              ),
              const SizedBox(height: 12),
              if (point != null)
                SizedBox(
                  height: 280,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: FlutterMap(
                      key: ValueKey(point),
                      options: MapOptions(
                        initialCenter: point,
                        initialZoom: 16,
                      ),
                      children: [
                        tileLayer(context),
                        if (a.accuracy != null)
                          CircleLayer(
                            circles: [
                              CircleMarker(
                                point: point,
                                radius: a.accuracy!,
                                useRadiusInMeter: true,
                                color: _sosRed.withValues(alpha: 0.15),
                              ),
                            ],
                          ),
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: point,
                              width: 44,
                              height: 44,
                              child: const Icon(
                                AppIcons.mapPin,
                                color: _sosRed,
                                size: 44,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                )
              else
                const SoftCard(child: Text('Der Standort ist noch unbekannt.')),
              const SizedBox(height: 16),
              if (a.open && a.state == SosState.active)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _sosRed,
                    minimumSize: const Size.fromHeight(52),
                  ),
                  icon: const Icon(AppIcons.check),
                  label: const Text('Ich komme'),
                  onPressed: () => run(() => engine.api.sosComing(a.id)),
                ),
              if (phone != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(AppIcons.phoneCall),
                  label: Text('$name anrufen'),
                  onPressed: () => launchUrl(Uri(scheme: 'tel', path: phone)),
                ),
              ],
              if (a.mapLink != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(AppIcons.mapPin),
                  label: const Text('In Karten-App öffnen'),
                  onPressed: () =>
                      launchUrl(
                        Uri.parse(
                          'geo:${a.latitude},${a.longitude}?q=${a.latitude},${a.longitude}',
                        ),
                      ).catchError(
                        (Object _) => launchUrl(
                          Uri.parse(a.mapLink!),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                ),
              ],
              if (a.open) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => run(() => engine.api.sosResolve(a.id)),
                  child: const Text('Notfall beenden'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Adults decide how the button behaves: siren, texts without internet,
/// phone numbers and whom each member's button calls.
class SosSettingsScreen extends StatelessWidget {
  const SosSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      collections: const {Collections.sosSettings, 'members'},
      builder: (context, engine) {
        final s = SosSettings.fromRecord(
          engine.record(Collections.sosSettings, SosSettings.recordId),
        );
        final adults = [
          for (final m in engine.members)
            if (m.isAdult) m,
        ];
        final others = [
          for (final m in engine.members)
            if (!m.isGuest) m,
        ];
        final mayEdit = engine.me?.isAdult ?? false;
        void save(SosSettings value) => engine.put(
          Collections.sosSettings,
          SosSettings.recordId,
          value.toData(),
        );
        final accent = FamioColors.of(context).strong(FamioSection.settings);
        return SectionPage(
          section: FamioSection.settings,
          title: 'Notfallknopf',
          subtitle: 'SOS-Alarm an die Eltern',
          maxBodyWidth: 720,
          body: ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              const SoftCard(
                child: Text(
                  'Auf der Startseite (für Kinder groß) gibt es einen roten '
                  'SOS-Knopf. 3 Sekunden gedrückt halten: Alle Erwachsenen '
                  'bekommen einen lauten Alarm – auch in der Ruhezeit – und '
                  'sehen den Standort, eine halbe Stunde lang laufend. '
                  'Mit „Ich komme“ sieht das Kind, dass Hilfe unterwegs ist.',
                ),
              ),
              if (!mayEdit)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Nur Erwachsene können das ändern.'),
                ),
              SwitchListTile(
                secondary: const Icon(AppIcons.siren),
                title: const Text('Sirene am Handy'),
                subtitle: const Text(
                  'Lauter Ton, auch bei Lautlos (iPhone: solange Famio offen '
                  'ist). Aus: stiller Alarm.',
                ),
                value: s.siren,
                onChanged: mayEdit ? (v) => save(s.copyWith(siren: v)) : null,
              ),
              SwitchListTile(
                secondary: const Icon(AppIcons.chatsCircle),
                title: const Text('SMS ohne Internet (Android)'),
                subtitle: const Text(
                  'Ist das Handy offline, geht eine SMS mit dem Standort an '
                  'die Eltern.',
                ),
                value: s.sms,
                onChanged: mayEdit ? (v) => save(s.copyWith(sms: v)) : null,
              ),
              ListHeading('Telefonnummern', color: accent),
              for (final m in others)
                ListTile(
                  leading: const Icon(AppIcons.phone),
                  title: Text(m.displayName),
                  subtitle: Text(s.phones[m.id] ?? 'keine Nummer'),
                  trailing: mayEdit ? const Icon(AppIcons.pencilSimple) : null,
                  onTap: !mayEdit
                      ? null
                      : () async {
                          final number = await _askNumber(
                            context,
                            m.displayName,
                            s.phones[m.id] ?? '',
                          );
                          if (number == null) return;
                          save(
                            s.copyWith(
                              phones: {
                                ...s.phones..remove(m.id),
                                if (number.isNotEmpty) m.id: number,
                              },
                            ),
                          );
                        },
                ),
              ListHeading('Wen ruft der Knopf an?', color: accent),
              for (final m in others)
                ListTile(
                  title: Text(m.displayName),
                  trailing: DropdownButton<String>(
                    value: s.call[m.id] ?? '',
                    onChanged: !mayEdit
                        ? null
                        : (v) => save(
                            s.copyWith(
                              call: {
                                ...Map.of(s.call)..remove(m.id),
                                if (v != null && v.isNotEmpty) m.id: v,
                              },
                            ),
                          ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(
                          'Elternteil (${engine.member(s.callMember(m.id, adults))?.displayName ?? 'keiner mit Nummer'})',
                        ),
                      ),
                      for (final a in adults)
                        if (a.id != m.id && s.phones.containsKey(a.id))
                          DropdownMenuItem(
                            value: a.id,
                            child: Text(a.displayName),
                          ),
                      const DropdownMenuItem(
                        value: SosSettings.emergency,
                        child: Text('Notruf 112'),
                      ),
                      const DropdownMenuItem(
                        value: SosSettings.none,
                        child: Text('Nicht anrufen'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static Future<String?> _askNumber(
    BuildContext context,
    String name,
    String current,
  ) {
    final controller = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Nummer von $name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(hintText: 'z. B. 0170 1234567'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }
}
