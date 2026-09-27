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

/// Connects Famio with Google Calendar, Apple Calendar & co. via ICS links:
/// publishing Famio events (feeds) and showing external calendars
/// (subscriptions).
class CalendarConnectScreen extends StatelessWidget {
  const CalendarConnectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SectionPage(
      section: FamioSection.calendar,
      title: 'Kalender verbinden',
      subtitle: 'Apple, iCloud, Google, Outlook & Co.',
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 120),
            children: const [
              _SectionTitle(
                'Kalender-Apps direkt verbinden',
                'Apple Kalender (Mac, iPhone), Thunderbird oder DAVx⁵ auf '
                    'Android zeigen die Famio-Termine an – und du kannst sie '
                    'dort auch anlegen und ändern (CalDAV).',
              ),
              CalDavAppsSection(),
              Divider(height: 40),
              _SectionTitle(
                'Mit Google, iCloud, Nextcloud & Co. abgleichen',
                'Der Famio-Server gleicht Termine mit einem Kalender dort in '
                    'beide Richtungen ab, alle 15 Minuten und nach jeder '
                    'Änderung. Vertrauliche Termine bleiben in Famio.',
              ),
              CalDavAccountsSection(),
              Divider(height: 40),
              _SectionTitle(
                'Famio in anderen Kalendern anzeigen',
                'Ein privater Link, den du in Google Kalender, Apple Kalender '
                    'oder Outlook abonnierst. Änderungen in Famio erscheinen '
                    'dort automatisch (nur lesend).',
              ),
              _FeedsSection(),
              Divider(height: 40),
              _SectionTitle(
                'Andere Kalender in Famio anzeigen',
                'Schulkalender, Dienstplan oder dein Google- bzw. '
                    'iCloud-Kalender: Der Famio-Server ruft sie alle 30 '
                    'Minuten ab. Die Termine sind in Famio schreibgeschützt.',
              ),
              _SubscriptionsSection(),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, this.text);

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(text, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _Help extends StatelessWidget {
  const _Help(this.title, this.steps);

  final String title;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
      leading: const Icon(AppIcons.question, size: 22),
      childrenPadding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, step) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('${i + 1}. $step'),
          ),
      ],
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
            title: const Text('Neuer Kalender-Link'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'Name im anderen Kalender',
                  ),
                ),
                const SizedBox(height: 16),
                SegmentedButton<FeedScope>(
                  segments: const [
                    ButtonSegment(
                      value: FeedScope.all,
                      label: Text('Alle Termine'),
                    ),
                    ButtonSegment(
                      value: FeedScope.mine,
                      label: Text('Nur meine'),
                    ),
                  ],
                  selected: {scope},
                  onSelectionChanged: (s) => setState(() => scope = s.first),
                ),
                const SizedBox(height: 8),
                Text(
                  scope == FeedScope.all
                      ? 'Alle Familientermine.'
                      : 'Termine, bei denen du dabei bist, und Termine für '
                            'die ganze Familie.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Nur „Belegt“ zeigen'),
                  subtitle: const Text(
                    'Ohne Titel, Ort und Notizen – Google/Apple erfahren '
                    'nur, wann ihr keine Zeit habt. Vertrauliche Termine '
                    'fehlen immer.',
                  ),
                  value: hideDetails,
                  onChanged: (v) => setState(() => hideDetails = v),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Erstellen'),
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
        title: Text('Link „${feed.name}“ widerrufen?'),
        content: const Text(
          'Kalender, die diesen Link abonniert haben, erhalten keine '
          'Termine mehr.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Widerrufen'),
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
            title: const Text('Nur mit Verbindung zum Server verfügbar'),
            subtitle: Text('${snapshot.error}'),
            trailing: TextButton(
              onPressed: _reload,
              child: const Text('Erneut'),
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
                    'Google Kalender und Apple-Kalender-Abos über iCloud laden '
                    'den Link von ihren eigenen Servern. Dafür muss Famio per '
                    'HTTPS aus dem Internet erreichbar sein (z. B. über Nginx '
                    'Proxy Manager) und am Server FAMIO_PUBLIC_URL gesetzt '
                    'werden. Ohne das klappen nur Abos, die das Gerät selbst '
                    'lädt – etwa auf dem iPhone über die Einstellungen, im '
                    'Heimnetz.',
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
                  label: const Text('Link erstellen'),
                  onPressed: _create,
                ),
              ),
            ),
            const _Help('So geht’s in Google Kalender', [
              'calendar.google.com im Browser öffnen.',
              'Links bei „Weitere Kalender“ auf + → „Per URL“.',
              'Den kopierten Link einfügen und „Kalender hinzufügen“.',
              'Google aktualisiert Abos nur alle paar Stunden.',
            ]),
            const _Help('So geht’s in Apple Kalender (Mac)', [
              'Kalender-App → Ablage → Neues Kalenderabonnement …',
              'Den kopierten Link einfügen.',
              'Bei „Automatisch aktualisieren“ z. B. „Alle 5 Minuten“ wählen.',
              'Als Ort „Auf meinem Mac“ wählen. „iCloud“ funktioniert nur, '
                  'wenn Famio aus dem Internet erreichbar ist – sonst meldet '
                  'der Kalender „Anfrage fehlgeschlagen“.',
            ]),
            const _Help('So geht’s auf iPhone und iPad', [
              'Einstellungen → Kalender → Accounts → Account hinzufügen.',
              '„Andere“ → „Kalenderabo hinzufügen“.',
              'Den kopierten Link einfügen.',
              'Das iPhone lädt den Link selbst – im Heimnetz klappt das, '
                  'unterwegs nur mit öffentlicher Adresse oder VPN.',
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
        '${feed.scope == FeedScope.all ? 'alle Termine' : 'nur meine'}'
        '${feed.hideDetails ? ', nur „Belegt“' : ''}',
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
            tooltip: 'Link kopieren',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url.toString()));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Link kopiert')));
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'webcal') {
                Clipboard.setData(ClipboardData(text: webcal.toString()));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('webcal-Link kopiert')),
                );
              } else {
                onRevoke();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'webcal',
                child: Text('Als webcal:// kopieren'),
              ),
              PopupMenuItem(value: 'revoke', child: Text('Widerrufen')),
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
              existing == null ? 'Kalender abonnieren' : 'Abo bearbeiten',
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
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'z. B. Schule, Dienstplan',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'ICS-Adresse',
                      hintText: 'https://… oder webcal://…',
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
                      'Wer sieht die Termine?',
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
                child: const Text('Speichern'),
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
          name: name.text.trim().isEmpty ? 'Kalender' : name.text.trim(),
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
            status.error ?? '${sub.name}: ${status.eventCount} Termine geladen',
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
        title: Text('„${sub.name}“ entfernen?'),
        content: const Text(
          'Die importierten Termine verschwinden für alle, mit denen er '
          'geteilt ist. Der Originalkalender bleibt unverändert.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );
    if (ok == true) engine.deleteCalendarSubscription(sub.id);
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
                    ? 'Wird beim nächsten Abgleich geladen …'
                    : error ??
                          '${status.eventCount} Termine · aktualisiert '
                              '${status.lastSync == null ? '–' : dateTimeLabel(status.lastSync!)}';
                final mine = sub.editableBy(engine.memberId);
                final owner = sub.ownerId == null
                    ? null
                    : sub.ownerId == engine.memberId
                    ? 'dir'
                    : engine.member(sub.ownerId)?.displayName ?? 'jemandem';
                final who = owner == null
                    ? 'Für die ganze Familie'
                    : 'Von $owner · sichtbar für: '
                          '${sharingLabel(engine, sub.sharing)}';
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
                        tooltip: 'Jetzt abrufen',
                        onPressed: () => _refresh(context, sub),
                      ),
                      if (mine)
                        IconButton(
                          icon: const Icon(AppIcons.trash),
                          tooltip: 'Entfernen',
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
                label: const Text('Kalender abonnieren'),
                onPressed: () => _edit(context),
              ),
            ),
          ),
          const _Help('Adresse aus Google Kalender holen', [
            'calendar.google.com im Browser öffnen.',
            'Beim gewünschten Kalender ⋮ → „Einstellungen und Freigabe“.',
            'Ganz unten „Privatadresse im iCal-Format“ kopieren.',
            'Diese Adresse ist geheim – jeder mit dem Link sieht die Termine.',
          ]),
          const _Help('Adresse aus Apple iCloud holen', [
            'Kalender-App auf dem Mac oder iCloud.com öffnen.',
            'Beim Kalender auf „Teilen“ → „Öffentlicher Kalender“ aktivieren.',
            'Den angezeigten webcal://-Link kopieren.',
          ]),
          const _Help('Andere Quellen', [
            'Viele Schulen, Vereine und Abfallkalender bieten einen '
                'ICS- oder „iCal“-Link zum Abonnieren an.',
            'Outlook: Kalender veröffentlichen und den ICS-Link verwenden.',
          ]),
        ],
      ),
    );
  }
}
