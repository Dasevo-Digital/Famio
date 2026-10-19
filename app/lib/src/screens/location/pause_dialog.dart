import 'dart:async';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../data/family_data.dart';
import '../../design/app_icons.dart';
import '../../l10n.dart';
import '../../location/location_sharing.dart';
import '../../widgets/form_dialog.dart';
import '../../widgets/password_reveal.dart';

// Its own library: the settings pause sharing too, without loading the map.

/// Tells this phone's background service the current server and places.
Future<void> refreshLocationService(AppState state) => LocationSharing.refresh(
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
    tr.location1Hour: const Duration(hours: 1),
    tr.location3Hours: const Duration(hours: 3),
    tr.locationUntilTomorrowMorning: morning.difference(now),
    tr.locationUntilResumed: null,
  };
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => FormDialog(
        title: stopOnThisDevice
            ? tr.locationEndLocationSharing
            : tr.locationPauseNameSLocation(member.displayName),
        submitLabel: stopOnThisDevice ? tr.commonEnd2 : tr.locationPause,
        controllers: [code],
        fields: [
          Text(
            stopOnThisDevice
                ? tr.locationLocationNoLongerShared
                : tr.locationNeedsParentsCode,
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
                labelText: tr.adminParentsCode,
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
