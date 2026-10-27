import 'dart:convert';
import 'dart:io';

/// Checks that the tests and release checks of a release commit passed,
/// before tool/publish_gitea_release.sh publishes it: on Gitea (its own
/// runner, `.gitea/workflows/ci.yml`) and on GitHub (the mirror, with the
/// native builds). Without this, 2.0.18 went out while two of its jobs had
/// never run.
///
///   GITHUB_TOKEN=… GITEA_TOKEN=… GITEA_API=https://…/api/v1/repos/<owner>/<repo> \
///     dart tool/check_ci.dart v2.0.19
///
/// Both tokens only need to read. Every workflow below must have a finished,
/// successful run for the commit; a run still going or one that failed or
/// was cancelled stops the release.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('Aufruf: GITHUB_TOKEN=… dart tool/check_ci.dart <tag>');
    exit(64);
  }
  final env = Platform.environment;
  final missing = [
    for (final name in ['GITHUB_TOKEN', 'GITEA_TOKEN', 'GITEA_API'])
      if ((env[name] ?? '').isEmpty) name,
  ];
  if (missing.isNotEmpty) {
    stderr.writeln('Es fehlt: ${missing.join(', ')}');
    exit(64);
  }
  final sha = Process.runSync('git', ['rev-list', '-n1', args.single]);
  if (sha.exitCode != 0) {
    stderr.writeln('${args.single}: ${sha.stderr}'.trim());
    exit(65);
  }
  final commit = '${sha.stdout}'.trim();
  final github = await _get(
    Uri.https('api.github.com', '/repos/$githubRepository/actions/runs', {
      'head_sha': commit,
      'per_page': '100',
    }),
    {
      'authorization': 'Bearer ${env['GITHUB_TOKEN']}',
      'accept': 'application/vnd.github+json',
    },
  );
  final gitea = await _get(
    Uri.parse('${env['GITEA_API']}/commits/$commit/status'),
    {'authorization': 'token ${env['GITEA_TOKEN']}'},
  );
  final problems = [
    ...checkRuns([
      for (final run in github['workflow_runs'] as List? ?? const [])
        (run as Map).cast<String, Object?>(),
    ]),
    ...checkGitea([
      for (final status in gitea['statuses'] as List? ?? const [])
        (status as Map).cast<String, Object?>(),
    ]),
  ];
  final what = '${args.single} (${commit.substring(0, 8)})';
  if (problems.isNotEmpty) {
    stderr.writeln('CI für $what:');
    for (final p in problems) {
      stderr.writeln('  $p');
    }
    exit(1);
  }
  stdout.writeln(
    'CI für $what bestanden: Gitea ($giteaWorkflow), GitHub '
    '(${requiredWorkflows.map((w) => w.split('/').last).join(', ')})',
  );
}

Future<Map<String, Object?>> _get(Uri uri, Map<String, String> headers) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    headers.forEach(request.headers.set);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      stderr.writeln('${uri.host} antwortet ${response.statusCode}');
      exit(69);
    }
    return (jsonDecode(text) as Map).cast();
  } finally {
    client.close();
  }
}

const githubRepository = 'Dasevo-Digital/Famio';

/// The GitHub workflows a release commit runs: tests (from the push to
/// main) and the build checks of the tag.
const requiredWorkflows = [
  '.github/workflows/ci.yml',
  '.github/workflows/app-release.yml',
  '.github/workflows/server-release.yml',
];

/// The name of `.gitea/workflows/ci.yml`; its statuses are called
/// "Gitea CI / check (push)".
const giteaWorkflow = 'Gitea CI';

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
      problems.add('GitHub $path: kein Lauf für diesen Commit');
    } else if (run['status'] != 'completed') {
      problems.add('GitHub ${run['name']}: läuft noch (${run['status']})');
    } else if (run['conclusion'] != 'success') {
      problems.add(
        'GitHub ${run['name']}: ${run['conclusion']} – ${run['html_url']}',
      );
    }
  }
  return problems;
}

/// What stops the release, given the commit's statuses on Gitea (its
/// JSON, newest first per context): each job of [giteaWorkflow] passed.
List<String> checkGitea(List<Map<String, Object?>> statuses) {
  final ours = [
    for (final s in statuses)
      if ('${s['context']}'.startsWith('$giteaWorkflow /')) s,
  ];
  if (ours.isEmpty)
    return ['Gitea $giteaWorkflow: kein Lauf für diesen Commit'];
  return [
    for (final s in ours)
      if (s['status'] != 'success')
        'Gitea ${s['context']}: ${s['status']} – ${s['target_url']}',
  ];
}
