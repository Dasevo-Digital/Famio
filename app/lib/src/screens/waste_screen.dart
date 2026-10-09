import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../data/waste.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/dispose_with.dart';
import '../widgets/member_avatar.dart';
import '../l10n.dart';

/// The bins: which calendar has the pickup days, who puts them out (by
/// turns if wanted) and when Famio reminds on the evening before.
class WasteScreen extends StatelessWidget {
  const WasteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      collections: const {
        Collections.wasteSettings,
        Collections.calendarSubscriptions,
        Collections.events,
        Collections.externalEvents,
        'members',
      },
      builder: (context, engine) {
        final s = engine.wasteSettings;
        final mayEdit = engine.me?.isAdult ?? false;
        final people = [
          for (final m in engine.members)
            if (!m.isGuest && !m.isService) m,
        ];
        final subs = engine.calendarSubscriptions;
        final c = FamioColors.of(context);
        final accent = c.strong(FamioSection.chores);
        void save({
          Object? sourceId = _keep,
          List<String>? memberIds,
          bool? rotate,
          int? remindHour,
        }) => engine.saveWasteSettings(
          WasteSettings(
            sourceId: sourceId == _keep ? s.sourceId : sourceId as String?,
            memberIds: memberIds ?? s.memberIds,
            rotate: rotate ?? s.rotate,
            remindHour: remindHour ?? s.remindHour,
          ),
        );
        final today = DateUtils.dateOnly(DateTime.now());
        final pickups = engine
            .wastePickups(today, today.add(const Duration(days: 60)))
            .take(8)
            .toList();
        final date = DateFormat.MMMEd(appLanguage);
        return SectionPage(
          section: FamioSection.chores,
          title: tr.settingsWaste,
          subtitle: tr.wasteWhenWhichBinHas,
          maxBodyWidth: 720,
          body: ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              SoftCard(child: Text(tr.wasteFamioRemindsYouEvening)),
              if (!mayEdit)
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(tr.sosOnlyAdultsCanChange),
                ),
              ListHeading(tr.wasteCollectionDates, color: accent),
              RadioGroup<String?>(
                groupValue: subs.any((x) => x.id == s.sourceId)
                    ? s.sourceId
                    : null,
                onChanged: (v) {
                  if (mayEdit) save(sourceId: v);
                },
                child: Column(
                  children: [
                    RadioListTile<String?>(
                      value: null,
                      enabled: mayEdit,
                      title: Text(tr.wasteDetectAutomatically),
                      subtitle: Text(tr.wasteAllDayEventsLike),
                    ),
                    for (final sub in subs)
                      RadioListTile<String?>(
                        value: sub.id,
                        enabled: mayEdit,
                        title: Text(sub.name),
                        subtitle: Text(tr.wasteAllEventsCalendar),
                      ),
                  ],
                ),
              ),
              if (mayEdit)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(AppIcons.plus),
                    label: Text(tr.wasteSubscribe),
                    onPressed: () async {
                      final id = await _subscribe(context, engine);
                      if (id != null) save(sourceId: id);
                    },
                  ),
                ),
              ListHeading(tr.wasteWhoPutsThemOut, color: accent),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in people)
                      FilterChip(
                        avatar: MemberAvatar(m, radius: 10),
                        label: Text(m.displayName),
                        selected: s.memberIds.contains(m.id),
                        onSelected: mayEdit
                            ? (on) => save(
                                memberIds: [
                                  for (final p in people)
                                    if (p.id == m.id
                                        ? on
                                        : s.memberIds.contains(p.id))
                                      p.id,
                                ],
                              )
                            : null,
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  s.memberIds.isEmpty
                      ? tr.wasteNobodyChosenAllAdults
                      : tr.wasteOnlyThoseChosenReminded,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              SwitchListTile(
                secondary: const Icon(AppIcons.arrowsClockwise),
                title: Text(tr.wasteTakeTurnsWeekly),
                subtitle: Text(tr.wasteEachWeekSSomeone),
                value: s.rotate,
                onChanged: mayEdit && s.memberIds.length > 1
                    ? (v) => save(rotate: v)
                    : null,
              ),
              ListTile(
                leading: const Icon(AppIcons.bell),
                title: Text(tr.wasteReminderEveningBefore),
                trailing: DropdownButton<int>(
                  value: s.remindHour,
                  items: [
                    for (var h = 15; h <= 22; h++)
                      DropdownMenuItem(
                        value: h,
                        child: Text(
                          DateFormat.jm(
                            appLanguage,
                          ).format(DateTime(2000, 1, 1, h)),
                        ),
                      ),
                  ],
                  onChanged: mayEdit
                      ? (v) => v == null ? null : save(remindHour: v)
                      : null,
                ),
              ),
              if (mayEdit && !engine.wasteConfigured)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.icon(
                    icon: const Icon(AppIcons.check),
                    label: Text(tr.wasteTurnReminders),
                    onPressed: () => save(),
                  ),
                ),
              ListHeading(tr.wasteNextCollections, color: accent),
              if (pickups.isEmpty)
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(tr.wasteNoCollectionFoundNext),
                ),
              for (final p in pickups)
                ListTile(
                  leading: const Icon(AppIcons.recycle),
                  title: Text(p.label),
                  subtitle: Text(
                    [
                      date.format(p.day),
                      if (engine.wasteResponsible(p) case final who
                          when who.isNotEmpty && s.memberIds.isNotEmpty)
                        who.map((m) => m.displayName).join(', '),
                    ].join(' · '),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Adds the municipality's calendar as a subscription for the family;
  /// returns its id.
  static Future<String?> _subscribe(
    BuildContext context,
    SyncEngine engine,
  ) async {
    final url = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => DisposeWith(
        controllers: [url],
        child: StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(tr.wasteSubscribe),
            content: SizedBox(
              width: 420,
              child: TextField(
                controller: url,
                autofocus: true,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: tr.wasteCalendarAddressIcs,
                  hintText: tr.calendarHttpsWebcal,
                  errorText: error,
                ),
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
                child: Text(tr.wasteSubscribe2),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return null;
    final id = newId();
    engine.saveCalendarSubscription(
      CalendarSubscription(
        id: id,
        name: tr.settingsWaste,
        url: url.text.trim(),
        color: famioPalette.last,
        ownerId: engine.memberId,
      ),
    );
    return id;
  }
}

const _keep = Object();
