import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n.dart';

/// One version's section of `CHANGELOG.md`.
class ChangelogEntry {
  const ChangelogEntry(this.version, this.title, this.points);

  final String version;
  final String title;
  final List<String> points;
}

/// The `## <version> – <title>` sections with their `- ` points (wrapped
/// lines joined), newest first as in the file.
List<ChangelogEntry> parseChangelog(String text) {
  final entries = <ChangelogEntry>[];
  String? version;
  var title = '';
  var points = <String>[];
  void close() {
    if (version != null) entries.add(ChangelogEntry(version, title, points));
  }

  for (final raw in text.split('\n')) {
    final line = raw.trimRight();
    final heading = RegExp(r'^## (\S+)(?:\s+[–-]\s+(.*))?$').firstMatch(line);
    if (heading != null) {
      close();
      version = heading[1];
      title = heading[2] ?? '';
      points = [];
    } else if (version != null && line.startsWith('- ')) {
      points.add(line.substring(2));
    } else if (version != null && line.startsWith('  ') && points.isNotEmpty) {
      points[points.length - 1] = '${points.last} ${line.trim()}';
    }
  }
  close();
  return entries;
}

Future<List<ChangelogEntry>> loadChangelog() async =>
    parseChangelog(await rootBundle.loadString('CHANGELOG.md'));

/// Shows what is new in [entries] (the first expanded).
Future<void> showWhatsNew(BuildContext context, List<ChangelogEntry> entries) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          children: [
            for (final (i, e) in entries.indexed) ...[
              if (i > 0) const SizedBox(height: 16),
              Text(
                i == 0
                    ? tr.whatsNewNewVersionTitle(
                        e.version,
                        e.title.isEmpty ? '' : ': ${e.title}',
                      )
                    : '${e.version}${e.title.isEmpty ? '' : ' – ${e.title}'}',
                style: i == 0
                    ? Theme.of(context).textTheme.headlineSmall
                    : Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              for (final p in e.points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  '),
                      Expanded(child: Text(p)),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Text(
              tr.whatsNewOlderVersionsListedReleases,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );

/// After an update: shows the new version's section once. A fresh install
/// only remembers the version.
Future<void> maybeShowWhatsNew(BuildContext context) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final version = (await PackageInfo.fromPlatform()).version;
    final seen = prefs.getString('whatsNew.seen');
    await prefs.setString('whatsNew.seen', version);
    if (seen == null || seen == version) return;
    final entries = await loadChangelog();
    final current = entries.where((e) => e.version == version).toList();
    if (current.isEmpty || !context.mounted) return;
    await showWhatsNew(context, current);
  } catch (_) {
    // Never block the start over release notes.
  }
}
