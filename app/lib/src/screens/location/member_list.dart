part of '../location_screens.dart';

class _MemberList extends StatelessWidget {
  const _MemberList({
    required this.engine,
    required this.locations,
    required this.onFocus,
    this.scrollable = true,
  });

  final SyncEngine engine;
  final Map<String, MemberLocation> locations;
  final void Function(MemberLocation) onFocus;
  final bool scrollable;

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
      primary: scrollable,
      shrinkWrap: !scrollable,
      physics: scrollable ? null : const NeverScrollableScrollPhysics(),
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
            canAsk: me.isAdult,
            onTap: locations[m.id] == null
                ? null
                : () => onFocus(locations[m.id]!),
          ),
        if (me.isAdult) RecentCheckIns(engine: engine),
        if (engine.places.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              tr.locationTipAddPlacesLike,
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
    this.canAsk = false,
    this.onTap,
  });

  final FamilyMember member;
  final MemberLocation? location;
  final Place? place;
  final bool isMe;
  final bool canManage;

  /// An adult: may ask for a check-in and let the phone ring.
  final bool canAsk;
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
            tr.locationBatteryBattery(l.battery),
        ].join(' · '),
        style: warn ? TextStyle(color: c.danger) : null,
      ),
      onTap: onTap,
      trailing: canHistory || canManage || (canAsk && !isMe)
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
                  case 'ring':
                    await _ring(context);
                  case 'checkin':
                    await _askCheckIn(context);
                }
              },
              itemBuilder: (_) => [
                if (canHistory)
                  PopupMenuItem(
                    value: 'history',
                    child: Text(tr.pregnancyHistory),
                  ),
                if (canManage && l != null && l.state != SharingState.paused)
                  PopupMenuItem(value: 'pause', child: Text(tr.locationPause)),
                if (canManage && l?.state == SharingState.paused)
                  PopupMenuItem(
                    value: 'resume',
                    child: Text(tr.locationResume),
                  ),
                if (canAsk && !isMe) ...[
                  PopupMenuItem(
                    value: 'checkin',
                    child: Text(tr.locationAskCheck),
                  ),
                  PopupMenuItem(
                    value: 'ring',
                    child: Text(tr.locationRingPhone),
                  ),
                ],
              ],
            )
          : null,
    );
  }

  Future<void> _askCheckIn(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AppScope.read(context).engine!.api.requestCheckIn(member.id);
      messenger.showSnackBar(
        SnackBar(content: Text(tr.locationNameWasAsked(member.displayName))),
      );
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _ring(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = AppScope.read(context).engine!.api;
    try {
      await api.ringMember(member.id);
      final reach = await api
          .reachability()
          .then<Reachability?>((r) => r[member.id])
          .catchError((Object _) => null);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            reach == null || reach.reachable
                ? tr.locationNameSPhoneRings(member.displayName)
                : tr.locationSentButNameS(member.displayName),
          ),
        ),
      );
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
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
