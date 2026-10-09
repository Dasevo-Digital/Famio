part of '../admin_screens.dart';

/// A member's calendar profile: which calendars other members shared with
/// them appear in their Famio. Hidden ones never reach their devices.
class _MemberCalendars extends StatefulWidget {
  const _MemberCalendars({required this.member, required this.isMe});

  final FamilyMember member;
  final bool isMe;

  @override
  State<_MemberCalendars> createState() => _MemberCalendarsState();
}

class _MemberCalendarsState extends State<_MemberCalendars> {
  late Future<List<MemberCalendar>> _calendars = _api.memberCalendars(
    widget.member.id,
  );
  var _busy = false;

  FamioApiClient get _api => AppScope.read(context).engine!.api;

  Future<void> _toggle(List<MemberCalendar> all, MemberCalendar c) async {
    setState(() => _busy = true);
    final hidden = {
      for (final x in all)
        if (x.hidden) x.source,
    };
    c.hidden ? hidden.remove(c.source) : hidden.add(c.source);
    final engine = AppScope.read(context).engine!;
    final future = _api.setMemberCalendars(widget.member.id, hidden);
    try {
      await future;
      if (mounted) setState(() => _calendars = future);
      await engine.sync();
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final engine = AppScope.of(context).engine!;
    final name = widget.member.displayName;
    return FutureBuilder(
      future: _calendars,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ListTile(
            leading: const Icon(AppIcons.cloudSlash),
            title: Text(tr.commonOnlyWithServer),
            trailing: TextButton(
              onPressed: () => setState(
                () => _calendars = _api.memberCalendars(widget.member.id),
              ),
              child: Text(tr.commonAgain),
            ),
          );
        }
        final all = snapshot.data;
        if (all == null) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(switch ((all.isEmpty, widget.isMe)) {
                (true, true) => tr.memberCalendarsNoneMe,
                (true, false) => tr.memberCalendarsNone(name),
                (false, true) => tr.memberCalendarsSharedMe,
                (false, false) => tr.memberCalendarsShared(name),
              }, style: TextStyle(color: c.inkSoft)),
            ),
            for (final cal in all)
              SwitchListTile(
                secondary: Icon(switch (cal.kind) {
                  'subscription' => AppIcons.link,
                  _ => AppIcons.arrowsLeftRight,
                }),
                title: Text(cal.name),
                subtitle: Text(
                  [
                    switch (cal.kind) {
                      'google' => 'Google',
                      'caldav' => 'CalDAV',
                      _ => tr.calendarSubscription,
                    },
                    cal.ownerId == null
                        ? tr.memberCalendarsWholeFamily
                        : tr.memberCalendarsName(
                            engine.member(cal.ownerId)?.displayName ??
                                tr.memberCalendarsUnknown,
                          ),
                  ].join(' · '),
                ),
                value: !cal.hidden,
                onChanged: _busy ? null : (_) => _toggle(all, cal),
              ),
          ],
        );
      },
    );
  }
}
