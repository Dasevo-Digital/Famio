import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../l10n.dart';
import '../widgets/data_builder.dart';
import 'location_screens.dart' show tileLayer;
import 'member_emergency_screen.dart';
import 'sos_screens.dart' show sosRed;

// Its own library with the map: the web app loads it (and the map
// package) only when someone opens an emergency.

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
        Collections.memberEmergency,
        'members',
      },
      builder: (context, engine) {
        final record = engine.record(Collections.sosAlerts, alertId);
        if (record == null) {
          return Scaffold(body: Center(child: Text(tr.sosNotFound)));
        }
        final a = SosAlert.fromRecord(record);
        final name = engine.member(a.memberId)?.displayName ?? tr.commonSomeone;
        final phone = SosSettings.fromRecord(
          engine.record(Collections.sosSettings, SosSettings.recordId),
        ).phones[a.memberId];
        final time = DateFormat.jm(appLanguage);
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
            backgroundColor: a.open ? sosRed : null,
            foregroundColor: a.open ? Colors.white : null,
            title: Text(tr.sosFrom(name)),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(switch (a.state) {
                SosState.active => tr.sosNobodyHasReactedYet,
                SosState.coming => tr.sosNameWay(
                  engine.member(a.comingBy)?.displayName ?? tr.commonSomeone,
                ),
                SosState.resolved => tr.sosEndedTimeName(
                  time.format(a.resolvedAt ?? a.startedAt),
                  engine.member(a.resolvedBy)?.displayName ?? tr.sosSomeone,
                ),
              }, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                [
                  tr.sosTriggeredTime(time.format(a.startedAt)),
                  if (a.positionAt != null)
                    tr.sosLocationTimeAccuracy(
                      time.format(a.positionAt!),
                      a.accuracy == null
                          ? ''
                          : tr.sosMetersM(a.accuracy!.round()),
                    ),
                  if (a.battery != null) tr.sosBatteryBattery(a.battery!),
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
                                color: sosRed.withValues(alpha: 0.15),
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
                                color: sosRed,
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
                SoftCard(child: Text(tr.sosLocationStillUnknown)),
              const SizedBox(height: 16),
              if (a.open && a.state == SosState.active)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: sosRed,
                    minimumSize: const Size.fromHeight(52),
                  ),
                  icon: const Icon(AppIcons.check),
                  label: Text(tr.sosIMComing),
                  onPressed: () => run(() => engine.api.sosComing(a.id)),
                ),
              if (phone != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(AppIcons.phoneCall),
                  label: Text(tr.commonCallName(name)),
                  onPressed: () => launchUrl(Uri(scheme: 'tel', path: phone)),
                ),
              ],
              // Allergies, medicines, whom to call: for the adults helping.
              if (engine.memberEmergency(a.memberId) case final e?
                  when !e.isEmpty) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(AppIcons.firstAidKit),
                  label: Text(tr.memberEmergencyOf(name)),
                  onPressed: () => showMemberEmergency(context, a.memberId),
                ),
              ],
              if (a.mapLink != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(AppIcons.mapPin),
                  label: Text(tr.sosOpenInMaps),
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
                  child: Text(tr.sosEndEmergency),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
