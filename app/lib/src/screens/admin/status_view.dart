part of '../admin_screens.dart';

class _StatusView extends StatelessWidget {
  const _StatusView({required this.overview});

  final ServerOverview overview;

  static const _collectionLabels = {
    Collections.tasks: 'Aufgaben',
    Collections.shoppingLists: 'Einkaufslisten',
    Collections.shoppingItems: 'Einkaufsartikel',
    Collections.events: 'Termine',
    Collections.calendarSubscriptions: 'Kalender-Abos',
    Collections.externalEvents: 'Importierte Termine',
    Collections.chatMessages: 'Chat-Nachrichten',
    Collections.documents: 'Dokumente',
    Collections.children: 'Kinder',
    Collections.childEntries: 'Kinder-Einträge',
  };

  @override
  Widget build(BuildContext context) {
    final o = overview;
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.settings);
    return ListView(
      padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _Stat(AppIcons.hardDrives, 'Version', o.version),
            _Stat(
              AppIcons.activity,
              'Läuft seit',
              _ago(o.startedAt, suffix: false),
            ),
            _Stat(AppIcons.usersThree, 'Mitglieder', '${o.memberCount}'),
            _Stat(AppIcons.devices, 'Angemeldete Geräte', '${o.sessionCount}'),
            _Stat(
              AppIcons.arrowsClockwise,
              'Gerade verbunden',
              '${o.connectedClients}',
            ),
            _Stat(
              AppIcons.database,
              'Datenbank',
              fileSizeLabel(o.databaseBytes),
            ),
            _Stat(
              AppIcons.folderOpen,
              'Dateien',
              '${o.fileCount} · ${fileSizeLabel(o.fileBytes)}',
            ),
          ],
        ),
        ListHeading('Einträge', color: accent),
        SoftCard(
          child: Column(
            children: [
              for (final MapEntry(:key, :value) in o.recordCounts.entries)
                if (_collectionLabels[key] case final label?)
                  _InfoRow(label: label, value: '$value'),
              if (o.recordCounts.isEmpty)
                Text(
                  'Noch keine Einträge.',
                  style: TextStyle(color: c.inkSoft),
                ),
            ],
          ),
        ),
        ListHeading('Sicherheit', color: accent),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow(
                icon: AppIcons.database,
                label: 'Daten auf dem Server',
                value: o.encryptedAtRest ? 'verschlüsselt' : 'unverschlüsselt',
                note: o.encryptedAtRest && !o.keySeparate
                    ? 'Schlüssel liegt im Datenordner – FAMIO_KEY_FILE '
                          'woanders hin legen und getrennt sichern'
                    : o.encryptedAtRest
                    ? 'Schlüssel getrennt von den Daten'
                    : null,
              ),
              _InfoRow(
                icon: AppIcons.lock,
                label: 'HTTPS im Heimnetz',
                value: o.tlsPort == null ? 'aus' : 'Port ${o.tlsPort}',
              ),
              _InfoRow(
                icon: AppIcons.shield,
                label: 'Unverschlüsselter Zugriff',
                value: o.requireTls ? 'gesperrt' : 'erlaubt',
                note: o.requireTls
                    ? null
                    : 'FAMIO_REQUIRE_TLS=true, sobald alle Geräte HTTPS nutzen',
              ),
              if (o.tlsFingerprint case final fp?) ...[
                const SizedBox(height: 8),
                Text(
                  'Zertifikat-Fingerabdruck (zum Vergleich beim Verbinden):',
                  style: TextStyle(color: c.inkSoft),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  [
                    for (var i = 0; i < fp.split(':').length; i += 8)
                      fp.split(':').skip(i).take(8).join(':'),
                  ].join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ],
            ],
          ),
        ),
        ListHeading('Aktive Konfiguration', color: accent),
        SoftCard(
          child: Column(
            children: [
              _InfoRow(label: 'Zeitzone', value: o.effective.timeZone ?? '–'),
              _InfoRow(
                label: 'Öffentliche Adresse',
                value: o.effective.publicUrl ?? 'keine',
              ),
              _InfoRow(
                label: 'Max. Dateigröße',
                value: '${o.effective.maxUploadMb} MB',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.label, this.value);

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return SizedBox(
      width: 200,
      child: SoftCard(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            IconBlob(
              icon,
              color: c.strong(FamioSection.settings),
              background: c.tint(FamioSection.settings),
              size: 40,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    label,
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: c.inkSoft),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.icon,
    this.note,
  });

  final IconData? icon;
  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: c.inkSoft),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (note != null)
                  Text(
                    note!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: c.inkSoft),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ],
      ),
    );
  }
}

// --- shared -----------------------------------------------------------------
