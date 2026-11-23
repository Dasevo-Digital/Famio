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

/// Whether this phone shares its location, so that ending it there (also
/// by signing out) needs the parents' code.
Future<bool> sharingOnThisPhone() async =>
    LocationSharing.supported && (await LocationSharing.status()).enabled;

/// Ends sharing on this phone with the parents' [code]: only this phone
/// stops, nobody is paused, and the server drops what this phone measured
/// when its location token signs out (#587). Throws [ApiError] for a
/// wrong code.
Future<void> endSharingOnThisPhone(
  FamioApiClient api,
  FamilyMember member,
  String code,
) async {
  try {
    await api.checkLocationCode(code);
  } on ApiError catch (e) {
    // An older server ("Route not found"): pausing checked the code there.
    if (e.status != 404) rethrow;
    await api.pauseLocation(code: code, memberId: member.id);
  }
  await LocationSharing.disable(api: api);
}

/// Before signing out: true if this phone shares nothing or the parents'
/// code ended it (#337), false stays signed in.
Future<bool> confirmSharingEnds(BuildContext context) async {
  if (!await sharingOnThisPhone()) return true;
  if (!context.mounted) return false;
  return showPauseDialog(
    context,
    member: AppScope.read(context).me!,
    stopOnThisDevice: true,
  );
}

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
          if (stopOnThisDevice) {
            await endSharingOnThisPhone(api, member, code.text);
          } else {
            await api.pauseLocation(
              code: code.text,
              memberId: member.id,
              duration: duration,
            );
          }
          done = true;
          // Show the new state at once instead of with the next sync.
          unawaited(state.engine?.sync());
        },
      ),
    ),
  );
  return done;
}
