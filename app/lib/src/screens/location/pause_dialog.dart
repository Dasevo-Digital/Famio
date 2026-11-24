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
/// by signing out) may need the parents' code.
Future<bool> sharingOnThisPhone() async =>
    LocationSharing.supported && (await LocationSharing.status()).enabled;

/// Whether ending sharing on this phone (also by signing out) needs the
/// parents' code, asked before the code field shows (#595). Not when the
/// phone shares nothing, the family switched location sharing off (the
/// phones pause their reports anyway), the server has no code set, or an
/// older server cannot check one on the two-factor page.
///
/// It asks the server with an empty code, which never matches a set one.
Future<bool> endingSharingNeedsCode(AppState state) async {
  if (state.hiddenModules.contains(ServerSettings.locationModule)) {
    return false;
  }
  final api = state.engine?.api;
  final me = state.me;
  if (api == null || me == null) return false;
  try {
    if (!await sharingOnThisPhone()) return false;
  } catch (_) {
    // The phone cannot tell: signing out stops its service anyway.
    return false;
  }
  try {
    await _checkCode(api, me, '');
    return false;
  } on ApiError {
    // A code is set, or the server cannot be asked now: the field decides.
    return true;
  }
}

/// Ends sharing on this phone with the parents' [code]: only this phone
/// stops, nobody is paused, and the server drops what this phone measured
/// when its location token signs out (#587). Throws [ApiError] for a
/// wrong code, and with a neutral message when the phone fails to stop.
Future<void> endSharingOnThisPhone(
  FamioApiClient api,
  FamilyMember member,
  String code,
) async {
  await _checkCode(api, member, code);
  await stopSharingOnThisPhone(api);
}

/// Stops the phone's service and signs its location token out. Throws
/// [ApiError] with a neutral message when the phone fails at it, so that
/// dialogs and the lock screen show something (#337).
Future<void> stopSharingOnThisPhone(FamioApiClient api) async {
  try {
    await LocationSharing.disable(api: api);
  } catch (e) {
    if (e is ApiError) rethrow;
    throw ApiError(500, 'sharing_not_ended', tr.locationSharingNotEnded);
  }
}

/// Checks the parents' [code] before sharing ends on this phone. Returns
/// normally when it may end: the code is right, the family has none set
/// (#595), or an older server cannot check it on the two-factor page.
/// Throws [ApiError] otherwise (a wrong code, no connection).
Future<void> _checkCode(
  FamioApiClient api,
  FamilyMember member,
  String code,
) async {
  try {
    // Without a code set newer servers answer `noCode`: nothing to check.
    await api.checkLocationCode(code);
  } on ApiError catch (e) {
    if (_noCode(e)) return;
    // An older server ("Route not found"): pausing checked the code there.
    if (e.status != 404) rethrow;
    try {
      await api.pauseLocation(code: code, memberId: member.id);
    } on ApiError catch (e) {
      // Such a server also asks for the second factor before pausing: on
      // the two-factor page it cannot check the code at all, and the
      // member could not sign out otherwise.
      if (_noCode(e) || _secondFactorFirst(e)) return;
      rethrow;
    }
  }
}

/// No parents' code set, as servers said before they answered `noCode`.
bool _noCode(ApiError e) => e.code == 'no_code';

bool _secondFactorFirst(ApiError e) =>
    e.status == 403 &&
    (e.code == 'two_factor_required' || e.code == 'two_factor_setup_required');

/// Before signing out: true if this phone shares nothing, needs no code or
/// the parents' code ended it (#337, #595), false stays signed in.
Future<bool> confirmSharingEnds(BuildContext context) async {
  final state = AppScope.read(context);
  if (!await endingSharingNeedsCode(state)) return true;
  if (!context.mounted) return false;
  return showPauseDialog(context, member: state.me!, stopOnThisDevice: true);
}

/// "Beenden" on this phone: with the parents' code only when one is needed
/// (#595). Returns whether sharing ended.
Future<bool> endSharingAsking(BuildContext context) async {
  final state = AppScope.read(context);
  if (await endingSharingNeedsCode(state)) {
    if (!context.mounted) return false;
    return showPauseDialog(context, member: state.me!, stopOnThisDevice: true);
  }
  final engine = state.engine;
  if (engine == null) return false;
  await stopSharingOnThisPhone(engine.api);
  unawaited(engine.sync());
  return true;
}

/// Signs another phone's location sharing out with the parents' code
/// (#594): [device] names it. Returns whether it is signed out; a wrong
/// code shows in the dialog, which stays open for another try.
Future<bool> signOutLocationSession(
  BuildContext context, {
  required FamioApiClient api,
  required String sessionId,
  required String device,
}) async {
  final code = TextEditingController();
  var done = false;
  await showDialog<void>(
    context: context,
    builder: (context) => FormDialog(
      title: tr.locationEndLocationSharing,
      submitLabel: tr.settingsSignOut,
      controllers: [code],
      fields: [Text(tr.devicesLocationSignOutBody(device)), _CodeField(code)],
      onSubmit: () async {
        await api.deleteMySession(sessionId, code: code.text);
        done = true;
      },
    ),
  );
  return done;
}

/// The parents' code, hidden until revealed.
class _CodeField extends StatelessWidget {
  const _CodeField(this.code);

  final TextEditingController code;

  @override
  Widget build(BuildContext context) => PasswordReveal(
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
          _CodeField(code),
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
