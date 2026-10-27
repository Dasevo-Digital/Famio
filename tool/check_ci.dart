import 'dart:convert';
import 'dart:io';

/// Checks on GitHub that the tests and release checks of a release commit
/// passed, before tool/publish_gitea_release.sh publishes it. Gitea has no
/// runner of its own, so GitHub (the mirror) is the only CI: without this,
/// 2.0.18 went out while two of its jobs had never run.
///
///   GITHUB_TOKEN=… dart tool/check_ci.dart v2.0.19
///
/// The token only needs to read Actions. Every workflow below must have a
/// finished, successful run for the commit; a run still going or one that
/// failed or was cancelled stops the release.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('Aufruf: GITHUB_TOKEN=… dart tool/check_ci.dart <tag>');
    exit(64);
  }
  final token = Platform.environment['GITHUB_TOKEN'] ?? '';
  if (token.isEmpty) {
    stderr.writeln('GITHUB_TOKEN fehlt (Lesezugriff auf Actions)');
    exit(64);
  }
  final sha = Process.runSync('git', ['rev-list', '-n1', args.single]);
  if (sha.exitCode != 0) {
    stderr.writeln('${args.single}: ${sha.stderr}'.trim());
    exit(65);
  }
  final commit = '${sha.stdout}'.trim();
  final client = HttpClient();
  final Map<String, Object?> body;
  try {
    final request = await client.getUrl(
      Uri.https('api.github.com', '/repos/$repository/actions/runs', {
        'head_sha': commit,
        'per_page': '100',
      }),
    );
    request.headers
      ..set('authorization', 'Bearer $token')
      ..set('accept', 'application/vnd.github+json');
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      stderr.writeln('GitHub antwortet ${response.statusCode}');
      exit(69);
    }
    body = (jsonDecode(text) as Map).cast();
  } finally {
    client.close();
  }
  final problems = checkRuns([
    for (final run in body['workflow_runs'] as List? ?? const [])
      (run as Map).cast<String, Object?>(),
  ]);
  if (problems.isNotEmpty) {
    stderr.writeln('CI für ${args.single} (${commit.substring(0, 8)}):');
    for (final p in problems) {
      stderr.writeln('  $p');
    }
    exit(1);
  }
  stdout.writeln(
    'CI für ${args.single} (${commit.substring(0, 8)}): '
    '${requiredWorkflows.join(', ')} bestanden',
  );
}

const repository = 'Dasevo-Digital/Famio';

/// The workflows a release commit runs: tests (from the push to main) and
/// the build checks of the tag.
const requiredWorkflows = [
  '.github/workflows/ci.yml',
  '.github/workflows/app-release.yml',
  '.github/workflows/server-release.yml',
];

/// What stops the release, given the commit's runs (GitHub's JSON); the
/// newest run of each workflow counts (a manual rerun replaces a failed
/// one).
List<String> checkRuns(List<Map<String, Object?>> runs) {
  final newest = <String, Map<String, Object?>>{};
  for (final run in runs) {
    final path = run['path'] as String? ?? '';
    final known = newest[path];
    if (known == null ||
        '${run['created_at']}'.compareTo('${known['created_at']}') > 0) {
      newest[path] = run;
    }
  }
  final problems = <String>[];
  for (final path in requiredWorkflows) {
    final run = newest[path];
    if (run == null) {
      problems.add('$path: kein Lauf für diesen Commit');
    } else if (run['status'] != 'completed') {
      problems.add('${run['name']}: läuft noch (${run['status']})');
    } else if (run['conclusion'] != 'success') {
      problems.add('${run['name']}: ${run['conclusion']} – ${run['html_url']}');
    }
  }
  return problems;
}
