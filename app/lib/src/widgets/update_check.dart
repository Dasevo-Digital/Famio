import 'dart:convert';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n.dart';

/// The public list of Famio releases; asked only when an admin taps
/// "Nach neuer Version suchen", never in the background.
final releasesUrl = Uri.parse(
  'https://api.github.com/repos/Dasevo-Digital/Famio/releases/latest',
);

/// A published release.
class LatestRelease {
  const LatestRelease({
    required this.version,
    required this.url,
    this.published,
  });

  final String version;
  final Uri url;
  final DateTime? published;
}

Future<LatestRelease> fetchLatestRelease({http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final response = await c
        .get(releasesUrl, headers: {'accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception(tr.updateResponseCode(response.statusCode));
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return LatestRelease(
      version: '${json['tag_name']}'.replaceFirst(RegExp('^v'), ''),
      url: Uri.parse('${json['html_url']}'),
      published: DateTime.tryParse('${json['published_at']}'),
    );
  } finally {
    if (client == null) c.close();
  }
}

/// Asks for the newest release and compares it with [serverVersion] and
/// this app.
Future<void> showUpdateCheck(
  BuildContext context, {
  required String serverVersion,
}) async {
  final release = fetchLatestRelease();
  final app = PackageInfo.fromPlatform()
      .then<String?>((i) => i.version)
      .catchError((_) => null);
  await showDialog<void>(
    context: context,
    builder: (context) => FutureBuilder(
      future: Future.wait([release, app]),
      builder: (context, snapshot) {
        final theme = Theme.of(context);
        Widget body;
        LatestRelease? latest;
        if (snapshot.hasError) {
          body = Text(tr.updateReleaseListNotReachable);
        } else if (!snapshot.hasData) {
          body = const SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          );
        } else {
          latest = snapshot.data![0] as LatestRelease;
          final appVersion = snapshot.data![1] as String?;
          final serverOld = compareVersions(serverVersion, latest.version) < 0;
          final appOld =
              appVersion != null &&
              compareVersions(appVersion, latest.version) < 0;
          final date = latest.published;
          body = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                date == null
                    ? tr.updateLatest(latest.version)
                    : tr.updateLatestFrom(
                        latest.version,
                        DateFormat.yMd(appLanguage).format(date),
                      ),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                tr.updateServerVersionState(
                  serverVersion,
                  serverOld ? tr.updateAvailable : tr.updateCurrent,
                ),
              ),
              if (appVersion != null)
                Text(
                  tr.updateAppVersionState(
                    appVersion,
                    appOld ? tr.updateAvailable : tr.updateCurrent,
                  ),
                ),
              if (serverOld || appOld) ...[
                const SizedBox(height: 8),
                Text(tr.updateWhatSNewHow, style: theme.textTheme.bodySmall),
              ],
            ],
          );
        }
        return AlertDialog(
          title: Text(tr.updateFamioVersion),
          content: body,
          actions: [
            if (latest != null)
              TextButton(
                onPressed: () => launchUrl(
                  latest!.url,
                  mode: LaunchMode.externalApplication,
                ),
                child: Text(tr.updateViewRelease),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr.commonClose),
            ),
          ],
        );
      },
    ),
  );
}
