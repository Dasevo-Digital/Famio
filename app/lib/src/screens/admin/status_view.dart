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
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(AppIcons.cloudArrowDown),
              label: const Text('Nach neuer Version suchen'),
              onPressed: () =>
                  showUpdateCheck(context, serverVersion: o.version),
            ),
          ),
        ),
        ListHeading('Sicherungen', color: accent),
        const _BackupCard(),
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

/// Backups the server makes while running (nightly, and on request).
class _BackupCard extends StatefulWidget {
  const _BackupCard();

  @override
  State<_BackupCard> createState() => _BackupCardState();
}

class _BackupCardState extends State<_BackupCard> {
  late Future<Map<String, Object?>> _status = _load();
  var _busy = false;

  Future<Map<String, Object?>> _load() =>
      AppScope.read(context).engine!.api.backupStatus();

  Future<void> _now() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AppScope.read(context).engine!.api.backupNow();
      messenger.showSnackBar(
        const SnackBar(content: Text('Sicherung erstellt')),
      );
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = _load();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<Map<String, Object?>>(
      future: _status,
      builder: (context, snapshot) {
        final s = snapshot.data;
        if (s == null) {
          return snapshot.hasError
              ? const Text('Sicherungen: Status nicht verfügbar')
              : const LinearProgressIndicator();
        }
        if (s['enabled'] != true) {
          return const Text(
            'Ausgeschaltet (FAMIO_BACKUP_DIR=off). Sichere das Datenverzeichnis '
            'dann anders, z. B. mit Proxmox oder Home Assistant.',
          );
        }
        final backups = (s['backups'] as List? ?? const []).cast<Map>();
        final last = DateTime.tryParse(s['lastAt'] as String? ?? '');
        final bytes = backups.fold<int>(
          0,
          (sum, b) => sum + ((b['bytes'] as num?)?.toInt() ?? 0),
        );
        final error = s['lastError'] as String?;
        return SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                last == null
                    ? 'Noch keine Sicherung'
                    : 'Letzte Sicherung ${_ago(last)}',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                '${backups.length} Stände · ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB · '
                'jede Nacht um 3 Uhr, 7 Tage und 4 Wochen aufbewahrt '
                '(Dokumente und Fotos in den 2 neuesten)',
              ),
              Text(
                'Ordner: ${s['dir']} – verschlüsselt mit dem Datenschlüssel; '
                'zum Wiederherstellen werden die Sicherung und die '
                'Schlüsseldatei gebraucht.',
                style: theme.textTheme.bodySmall,
              ),
              if (error != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Fehler: $error',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(AppIcons.hardDrives, size: 18),
                label: const Text('Jetzt sichern'),
                onPressed: _busy ? null : _now,
              ),
            ],
          ),
        );
      },
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
