part of '../admin_screens.dart';

class _StatusView extends StatelessWidget {
  const _StatusView({required this.overview});

  final ServerOverview overview;

  static Map<String, String> get _collectionLabels => {
    Collections.tasks: tr.sectionTasks,
    Collections.shoppingLists: tr.commonShoppingLists,
    Collections.shoppingItems: tr.adminShoppingItems,
    Collections.events: tr.commonEvents,
    Collections.calendarSubscriptions: tr.adminCalendarSubscriptions,
    Collections.externalEvents: tr.adminImportedEvents,
    Collections.chatMessages: tr.adminChatMessages,
    Collections.documents: tr.sectionDocuments,
    Collections.children: tr.sectionKids,
    Collections.childEntries: tr.adminKidsEntries,
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
            _Stat(AppIcons.hardDrives, tr.settingsVersion, o.version),
            _Stat(
              AppIcons.activity,
              tr.adminRunningSince,
              _ago(o.startedAt, suffix: false),
            ),
            _Stat(AppIcons.usersThree, tr.commonMembers, '${o.memberCount}'),
            _Stat(AppIcons.devices, tr.adminSignedDevices, '${o.sessionCount}'),
            _Stat(
              AppIcons.arrowsClockwise,
              tr.adminConnectedRightNow,
              '${o.connectedClients}',
            ),
            _Stat(
              AppIcons.database,
              tr.adminDatabase,
              fileSizeLabel(o.databaseBytes),
            ),
            _Stat(
              AppIcons.folderOpen,
              tr.commonFiles,
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
              label: Text(tr.adminCheckNewVersion),
              onPressed: () =>
                  showUpdateCheck(context, serverVersion: o.version),
            ),
          ),
        ),
        ListHeading(tr.adminSetup, color: accent),
        const SetupChecklist(),
        ListHeading(tr.adminBackups, color: accent),
        const _BackupCard(),
        ListHeading(tr.commonEntries, color: accent),
        SoftCard(
          child: Column(
            children: [
              for (final MapEntry(:key, :value) in o.recordCounts.entries)
                if (_collectionLabels[key] case final label?)
                  _InfoRow(label: label, value: '$value'),
              if (o.recordCounts.isEmpty)
                Text(tr.adminNoEntriesYet, style: TextStyle(color: c.inkSoft)),
            ],
          ),
        ),
        ListHeading(tr.adminSecurity, color: accent),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow(
                icon: AppIcons.database,
                label: tr.adminDataServer,
                value: o.encryptedAtRest
                    ? tr.adminEncrypted
                    : tr.adminUnencrypted,
                note: o.encryptedAtRest && !o.keySeparate
                    ? tr.adminKeyDataFolderPut
                    : o.encryptedAtRest
                    ? tr.adminKeySeparateData
                    : null,
              ),
              _InfoRow(
                icon: AppIcons.lock,
                label: tr.adminHttpsHomeNetwork,
                value: o.tlsPort == null
                    ? tr.commonOff
                    : tr.adminPortPort(o.tlsPort!),
              ),
              _InfoRow(
                icon: AppIcons.shield,
                label: tr.adminUnencryptedAccess,
                value: o.requireTls ? tr.adminBlocked : tr.adminAllowed,
                note: o.requireTls ? null : tr.adminFamioRequireTlsTrue,
              ),
              if (o.tlsFingerprint case final fp?) ...[
                const SizedBox(height: 8),
                Text(
                  tr.adminCertificateFingerprintCompareWhen,
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
        ListHeading(tr.adminActiveConfiguration, color: accent),
        SoftCard(
          child: Column(
            children: [
              _InfoRow(
                label: tr.adminTimeZone,
                value: o.effective.timeZone ?? '–',
              ),
              _InfoRow(
                label: tr.adminPublicAddress,
                value: o.effective.publicUrl ?? tr.commonNoneLower,
              ),
              _InfoRow(
                label: tr.adminMaxFileSize,
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

  Future<void> _check() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final c = await AppScope.read(context).engine!.api.checkBackup();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            c['ok'] == true
                ? tr.adminBackupCheckedCanRestored
                : tr.adminBackupFaultyProblems(
                    [
                      for (final p in c['problems'] as List? ?? const [])
                        localizeServerText('$p'),
                    ].join('; '),
                  ),
          ),
        ),
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

  Future<void> _now() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AppScope.read(context).engine!.api.backupNow();
      messenger.showSnackBar(SnackBar(content: Text(tr.adminBackupCreated)));
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
              ? Text(tr.adminBackupsStatusNotAvailable)
              : const LinearProgressIndicator();
        }
        if (s['enabled'] != true) {
          return Text(tr.adminTurnedOffFamioBackup);
        }
        final backups = (s['backups'] as List? ?? const []).cast<Map>();
        final last = DateTime.tryParse(s['lastAt'] as String? ?? '');
        final bytes = backups.fold<int>(
          0,
          (sum, b) => sum + ((b['bytes'] as num?)?.toInt() ?? 0),
        );
        final error = switch (s['lastError']) {
          final String e => localizeServerText(e),
          _ => null,
        };
        final check = (s['lastCheck'] as Map?)?.cast<String, Object?>();
        return SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                last == null
                    ? tr.adminNoBackupYet
                    : tr.adminLastBackupAgo(_ago(last)),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                tr.adminCountVersionsSizeMb(
                  backups.length,
                  decimal(bytes / 1024 / 1024),
                ),
              ),
              Text(
                tr.adminFolderFolderEncryptedData('${s['dir']}'),
                style: theme.textTheme.bodySmall,
              ),
              if (error != null) ...[
                const SizedBox(height: 4),
                Text(
                  tr.commonErrorWith(error),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              if (check != null) ...[
                const SizedBox(height: 8),
                _BackupCheckLine(check),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(AppIcons.hardDrives, size: 18),
                    label: Text(tr.adminBackUpNow),
                    onPressed: _busy ? null : _now,
                  ),
                  if (backups.isNotEmpty)
                    OutlinedButton.icon(
                      icon: const Icon(AppIcons.check, size: 18),
                      label: Text(tr.adminCheckBackup),
                      onPressed: _busy ? null : _check,
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The last test of a backup: restorable or what is wrong.
class _BackupCheckLine extends StatelessWidget {
  const _BackupCheckLine(this.check);

  final Map<String, Object?> check;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = check['ok'] == true;
    final at = DateTime.tryParse(check['at'] as String? ?? '');
    final problems = [
      for (final p in check['problems'] as List? ?? const [])
        localizeServerText('$p'),
    ];
    final notes = [
      for (final n in check['notes'] as List? ?? const [])
        localizeServerText('$n'),
    ];
    final color = ok ? FamioColors.of(context).ink : theme.colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? AppIcons.check : AppIcons.warningCircle,
          size: 18,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            [
              ok
                  ? tr.adminCheckedAgoCanRestored(
                      at == null ? '' : ' ${_ago(at)}',
                      '${check['records']}',
                      '${check['users']}',
                      '${check['files']}',
                      check['filesChecked'] == true
                          ? ''
                          : tr.adminWithoutFileContents,
                    )
                  : tr.adminLastCheckFailedProblems(problems.join('; ')),
              ...notes,
            ].join('\n'),
            style: theme.textTheme.bodySmall?.copyWith(color: color),
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
