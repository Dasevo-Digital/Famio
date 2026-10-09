import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../data/family_data.dart';
import '../format.dart';
import '../widgets/calendar_sharing.dart';
import '../widgets/data_builder.dart';
import '../widgets/dispose_with.dart';
import 'caldav_screens.dart';
import '../widgets/section_header.dart';
import '../widgets/undo_delete.dart';
import '../l10n.dart';

/// Connects Famio with Google Calendar, Apple Calendar & co. via ICS links:
/// publishing Famio events (feeds) and showing external calendars
/// (subscriptions).
class CalendarConnectScreen extends StatelessWidget {
  const CalendarConnectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SectionPage(
      section: FamioSection.calendar,
      title: tr.caldavConnectCalendar,
      subtitle: 'Apple, iCloud, Google, Outlook & Co.',
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 120),
            children: [
              SectionHeader(
                tr.calendarConnectCalendarAppsDirectly,
                tr.calendarAppleCalendarMacIphone,
              ),
              CalDavAppsSection(),
              Divider(height: 40),
              SectionHeader(
                tr.calendarSyncGoogleIcloudNextcloud,
                tr.calendarFamioServerSyncsEvents,
              ),
              CalDavAccountsSection(),
              Divider(height: 40),
              SectionHeader(
                tr.calendarShowFamioOtherCalendars,
                tr.calendarPrivateLinkThatYou,
              ),
              _FeedsSection(),
              Divider(height: 40),
              SectionHeader(
                tr.calendarShowOtherCalendarsFamio,
                tr.calendarSchoolCalendarDutyRoster,
              ),
              _SubscriptionsSection(),
            ],
          ),
        ),
      ),
    );
  }
}

// --- feeds (export) ---------------------------------------------------------

class _FeedsSection extends StatefulWidget {
  const _FeedsSection();

  @override
  State<_FeedsSection> createState() => _FeedsSectionState();
}

class _FeedsSectionState extends State<_FeedsSection> {
  late Future<(List<CalendarFeed>, Uri?)> _feeds = _load();

  Future<(List<CalendarFeed>, Uri?)> _load() =>
      AppScope.read(context).engine!.api.calendarFeeds();

  void _reload() => setState(() {
    _feeds = _load();
  });

  Future<void> _create() async {
    final name = TextEditingController(text: 'Famio');
    var scope = FeedScope.all;
    var hideDetails = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => DisposeWith(
        controllers: [name],
        child: StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(tr.calendarNewCalendarLink),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: name,
                  decoration: InputDecoration(
                    labelText: tr.calendarNameOtherCalendar,
                  ),
                ),
                const SizedBox(height: 16),
                SegmentedButton<FeedScope>(
                  segments: [
                    ButtonSegment(
                      value: FeedScope.all,
                      label: Text(tr.calendarAllEvents),
                    ),
                    ButtonSegment(
                      value: FeedScope.mine,
                      label: Text(tr.calendarOnlyMine),
                    ),
                  ],
                  selected: {scope},
                  onSelectionChanged: (s) => setState(() => scope = s.first),
                ),
                const SizedBox(height: 8),
                Text(
                  scope == FeedScope.all
                      ? tr.calendarAllFamilyEvents
                      : tr.caldavEventsYouTakePart,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr.calendarShowOnlyBusy),
                  subtitle: Text(tr.calendarWithoutTitlePlaceNotes),
                  value: hideDetails,
                  onChanged: (v) => setState(() => hideDetails = v),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr.commonCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr.commonCreate),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok == true && mounted) {
      await _guard(
        () => AppScope.read(context).engine!.api.createCalendarFeed(
          name: name.text.trim().isEmpty ? 'Famio' : name.text.trim(),
          scope: scope,
          hideDetails: hideDetails,
        ),
      );
      _reload();
    }
  }

  Future<void> _revoke(CalendarFeed feed) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.calendarRevokeLinkName(feed.name)),
        content: Text(tr.calendarCalendarsThatSubscribedLink),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.commonRevoke),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _guard(
      () => AppScope.read(context).engine!.api.deleteCalendarFeed(feed.id),
    );
    _reload();
  }

  Future<void> _guard(Future<Object?> Function() action) async {
    try {
      await action();
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverUrl = AppScope.engineOf(context).api.baseUrl;
    final theme = Theme.of(context);
    return FutureBuilder(
      future: _feeds,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ListTile(
            leading: const Icon(AppIcons.cloudSlash),
            title: Text(tr.commonOnlyWithServer),
            subtitle: Text('${snapshot.error}'),
            trailing: TextButton(
              onPressed: _reload,
              child: Text(tr.commonAgain),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final (feeds, publicUrl) = snapshot.data!;
        final base = publicUrl ?? serverUrl;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (publicUrl == null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: SoftCard(
                  color: FamioColors.of(context).tint(FamioSection.home),
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    tr.calendarGoogleCalendarAppleCalendar,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            for (final feed in feeds)
              _FeedTile(
                feed: feed,
                url: base.resolve(feed.path),
                onRevoke: () => _revoke(feed),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  icon: const Icon(AppIcons.link),
                  label: Text(tr.calendarCreateLink),
                  onPressed: _create,
                ),
              ),
            ),
            HelpSteps(tr.calendarHowWorksGoogleCalendar, [
              tr.calendarOpenGoogleInBrowser,
              tr.calendarLeftOtherCalendarsTap,
              tr.calendarPasteCopiedLinkAdd,
              tr.calendarGoogleOnlyUpdatesSubscriptions,
            ]),
            HelpSteps(tr.calendarHowWorksAppleCalendar, [
              tr.calendarCalendarAppFileNew,
              tr.calendarPasteCopiedLink,
              tr.calendarAutoRefreshChooseE,
              tr.calendarChooseMyMacLocation,
            ]),
            HelpSteps(tr.calendarHowWorksIphoneIpad, [
              tr.calendarSettingsCalendarAccountsAdd,
              tr.calendarOtherAddSubscribedCalendar,
              tr.calendarPasteCopiedLink,
              tr.calendarIphoneLoadsLinkItself,
            ]),
          ],
        );
      },
    );
  }
}

class _FeedTile extends StatelessWidget {
  const _FeedTile({
    required this.feed,
    required this.url,
    required this.onRevoke,
  });

  final CalendarFeed feed;
  final Uri url;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final webcal = url.replace(
      scheme: url.scheme == 'https' ? 'webcals' : 'webcal',
    );
    return ListTile(
      leading: const Icon(AppIcons.link),
      title: Text(
        '${feed.name} · '
        '${feed.scope == FeedScope.all ? tr.calendarAllEvents2 : tr.calendarOnlyMine2}'
        '${feed.hideDetails ? tr.calendarOnlyBusy : ''}',
      ),
      subtitle: SelectableText(
        url.toString(),
        maxLines: 1,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(AppIcons.copy),
            tooltip: tr.calendarCopyLink,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url.toString()));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(tr.calendarLinkCopied)));
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'webcal') {
                Clipboard.setData(ClipboardData(text: webcal.toString()));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(tr.calendarWebcalLinkCopied)),
                );
              } else {
                onRevoke();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'webcal',
                child: Text(tr.calendarCopyWebcal),
              ),
              PopupMenuItem(value: 'revoke', child: Text(tr.commonRevoke)),
            ],
          ),
        ],
      ),
    );
  }
}

// --- subscriptions (import) -------------------------------------------------

class _SubscriptionsSection extends StatelessWidget {
  const _SubscriptionsSection();

  Future<void> _edit(
    BuildContext context, [
    CalendarSubscription? existing,
  ]) async {
    final engine = AppScope.engineOf(context);
    final name = TextEditingController(text: existing?.name);
    final url = TextEditingController(text: existing?.url);
    var color =
        existing?.color ??
        famioPalette[engine.calendarSubscriptions.length % famioPalette.length];
    // Legacy family subscriptions stay the family's.
    var sharing = existing?.sharing ?? const CalendarSharing.family();
    final owned = existing == null || existing.ownerId != null;
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => DisposeWith(
        controllers: [name, url],
        child: StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(
              existing == null
                  ? tr.calendarSubscribeCalendar
                  : tr.calendarEditSubscription,
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: name,
                    autofocus: existing == null,
                    decoration: InputDecoration(
                      labelText: tr.commonName,
                      hintText: 'z. B. Schule, Dienstplan',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: tr.calendarIcsAddress,
                      hintText: tr.calendarHttpsWebcal,
                      errorText: error,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final c in famioPalette)
                        InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => color = c),
                          child: CircleAvatar(
                            radius: 14,
                            backgroundColor: Color(c),
                            child: c == color
                                ? const Icon(
                                    AppIcons.check,
                                    size: 16,
                                    color: Colors.white,
                                  )
                                : null,
                          ),
                        ),
                    ],
                  ),
                  if (owned) ...[
                    const SizedBox(height: 16),
                    Text(
                      tr.calendarWhoSeesEvents,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    CalendarSharingPicker(
                      engine: engine,
                      value: sharing,
                      onChanged: (v) => setState(() => sharing = v),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr.commonCancel),
              ),
              FilledButton(
                onPressed: () {
                  final u = Uri.tryParse(url.text.trim());
                  const schemes = {'http', 'https', 'webcal', 'webcals'};
                  if (u == null ||
                      !schemes.contains(u.scheme) ||
                      u.host.isEmpty) {
                    setState(() => error = tr.calendarAddressMustStartHttps);
                    return;
                  }
                  Navigator.pop(context, true);
                },
                child: Text(tr.commonSave),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved == true) {
      engine.saveCalendarSubscription(
        CalendarSubscription(
          id: existing?.id ?? newId(),
          name: name.text.trim().isEmpty
              ? tr.sectionCalendar
              : name.text.trim(),
          url: url.text.trim(),
          color: color,
          ownerId: owned ? existing?.ownerId ?? engine.memberId : null,
          sharing: sharing,
        ),
      );
    }
  }

  Future<void> _refresh(BuildContext context, CalendarSubscription sub) async {
    final engine = AppScope.engineOf(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await engine.sync(); // Make sure the server knows the subscription.
      final status = await engine.api.refreshSubscription(sub.id);
      await engine.sync();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            status.error ??
                tr.calendarNameCountEventsLoaded(sub.name, status.eventCount),
          ),
        ),
      );
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete(BuildContext context, CalendarSubscription sub) async {
    final engine = AppScope.engineOf(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.commonRemoveName(sub.name)),
        content: Text(tr.calendarImportedEventsDisappearEveryone),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.commonRemove),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      deleteWithUndo(
        context,
        what: sub.name,
        collections: const {Collections.calendarSubscriptions},
        delete: () => engine.deleteCalendarSubscription(sub.id),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DataBuilder(
      collections: const {
        Collections.calendarSubscriptions,
        Collections.calendarSyncStatus,
      },
      builder: (context, engine) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final sub in engine.calendarSubscriptions)
            Builder(
              builder: (context) {
                final status = engine.subscriptionStatus(sub.id);
                final error = status?.error;
                final subtitle = status == null
                    ? tr.calendarWillLoadedNextSync
                    : error ??
                          tr.calendarCountEventsUpdatedWhen(
                            status.eventCount,
                            status.lastSync == null
                                ? '–'
                                : dateTimeLabel(status.lastSync!),
                          );
                final mine = sub.editableBy(engine.memberId);
                final owner = sub.ownerId == null
                    ? null
                    : sub.ownerId == engine.memberId
                    ? tr.calendarYou
                    : engine.member(sub.ownerId)?.displayName ??
                          tr.calendarSomeone;
                final who = owner == null
                    ? tr.calendarWholeFamily
                    : tr.calendarOwnerVisibleWho(
                        owner,
                        sharingLabel(engine, sub.sharing),
                      );
                return ListTile(
                  leading: CircleAvatar(
                    radius: 10,
                    backgroundColor: Color(sub.color ?? 0xFF607D8B),
                  ),
                  title: Text(sub.name),
                  subtitle: Text(
                    '$subtitle\n$who',
                    style: error == null
                        ? null
                        : TextStyle(color: theme.colorScheme.error),
                  ),
                  isThreeLine: true,
                  onTap: mine ? () => _edit(context, sub) : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(AppIcons.arrowsClockwise),
                        tooltip: tr.calendarFetchNow,
                        onPressed: () => _refresh(context, sub),
                      ),
                      if (mine)
                        IconButton(
                          icon: const Icon(AppIcons.trash),
                          tooltip: tr.commonRemove,
                          onPressed: () => _delete(context, sub),
                        ),
                    ],
                  ),
                );
              },
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                icon: const Icon(AppIcons.plus),
                label: Text(tr.calendarSubscribeCalendar),
                onPressed: () => _edit(context),
              ),
            ),
          ),
          HelpSteps(tr.calendarGetAddressGoogleCalendar, [
            tr.calendarOpenGoogleInBrowser,
            tr.calendarCalendarYouWantSettings,
            tr.calendarVeryBottomCopySecret,
            tr.calendarAddressSecretAnyoneLink,
          ]),
          HelpSteps(tr.calendarGetAddressAppleIcloud, [
            tr.calendarOpenCalendarAppMac,
            tr.calendarCalendarTapShareEnable,
            tr.calendarCopyWebcalLinkShown,
          ]),
          HelpSteps(tr.calendarOtherSources, [
            tr.calendarManySchoolsClubsWaste,
            tr.calendarOutlookPublishCalendarUse,
          ]),
        ],
      ),
    );
  }
}
