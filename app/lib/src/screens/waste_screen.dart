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
        final date = DateFormat('EEE, d. MMM', 'de');
        return SectionPage(
          section: FamioSection.chores,
          title: 'Abfallkalender',
          subtitle: 'Wann welche Tonne raus muss',
          maxBodyWidth: 720,
          body: ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              const SoftCard(
                child: Text(
                  'Famio erinnert am Vorabend, wer welche Tonne rausstellt, '
                  'und zeigt es auf der Startseite und der Wandanzeige. Die '
                  'Abholtermine kommen aus dem Abfuhrkalender eurer Gemeinde '
                  '– fast alle Entsorger bieten ihn zum Abonnieren an '
                  '(„iCal“, „ICS“ oder „Kalender exportieren“ auf ihrer '
                  'Webseite oder in ihrer App).',
                ),
              ),
              if (!mayEdit)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Nur Erwachsene können das ändern.'),
                ),
              ListHeading('Abholtermine', color: accent),
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
                      title: const Text('Automatisch erkennen'),
                      subtitle: const Text(
                        'Ganztägige Termine wie „Gelber Sack“, „Restmüll“ oder '
                        '„Altpapier“ – auch selbst eingetragene',
                      ),
                    ),
                    for (final sub in subs)
                      RadioListTile<String?>(
                        value: sub.id,
                        enabled: mayEdit,
                        title: Text(sub.name),
                        subtitle: const Text('Alle Termine dieses Kalenders'),
                      ),
                  ],
                ),
              ),
              if (mayEdit)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(AppIcons.plus),
                    label: const Text('Abfuhrkalender abonnieren'),
                    onPressed: () async {
                      final id = await _subscribe(context, engine);
                      if (id != null) save(sourceId: id);
                    },
                  ),
                ),
              ListHeading('Wer stellt raus?', color: accent),
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
                      ? 'Niemand gewählt: Alle Erwachsenen werden erinnert.'
                      : 'Nur die Gewählten werden erinnert.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              SwitchListTile(
                secondary: const Icon(AppIcons.arrowsClockwise),
                title: const Text('Wöchentlich abwechseln'),
                subtitle: const Text('Jede Woche ist jemand anderes dran'),
                value: s.rotate,
                onChanged: mayEdit && s.memberIds.length > 1
                    ? (v) => save(rotate: v)
                    : null,
              ),
              ListTile(
                leading: const Icon(AppIcons.bell),
                title: const Text('Erinnerung am Vorabend'),
                trailing: DropdownButton<int>(
                  value: s.remindHour,
                  items: [
                    for (var h = 15; h <= 22; h++)
                      DropdownMenuItem(value: h, child: Text('$h:00 Uhr')),
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
                    label: const Text('Erinnerungen einschalten'),
                    onPressed: () => save(),
                  ),
                ),
              ListHeading('Nächste Abholungen', color: accent),
              if (pickups.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'In den nächsten zwei Monaten keine Abholung gefunden. '
                    'Ein neues Abo braucht ein paar Minuten, bis die Termine '
                    'da sind.',
                  ),
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
            title: const Text('Abfuhrkalender abonnieren'),
            content: SizedBox(
              width: 420,
              child: TextField(
                controller: url,
                autofocus: true,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Adresse des Kalenders (ICS)',
                  hintText: 'https://… oder webcal://…',
                  errorText: error,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () {
                  final u = Uri.tryParse(url.text.trim());
                  const schemes = {'http', 'https', 'webcal', 'webcals'};
                  if (u == null ||
                      !schemes.contains(u.scheme) ||
                      u.host.isEmpty) {
                    setState(
                      () => error =
                          'Adresse muss mit https:// oder webcal:// beginnen',
                    );
                    return;
                  }
                  Navigator.pop(context, true);
                },
                child: const Text('Abonnieren'),
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
        name: 'Abfallkalender',
        url: url.text.trim(),
        color: famioPalette.last,
        ownerId: engine.memberId,
      ),
    );
    return id;
  }
}

const _keep = Object();
