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
///
/// A job GitHub never gave a machine (macOS runners ran out for 2.0.23 and
/// 2.0.32) is not a failed check. With GITHUB_RERUN_TOKEN (fine-grained,
/// "Actions: Read and write" on the repository) such runs are started again
/// and awaited (at most FAMIO_CI_WAIT_MINUTES, default 90); without it the
/// report says so, with the run to restart by hand.
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
  final github = _GitHub(env['GITHUB_TOKEN']!, env['GITHUB_RERUN_TOKEN']);
  final wait = Duration(
    minutes: int.tryParse(env['FAMIO_CI_WAIT_MINUTES'] ?? '') ?? 90,
  );
  // Run id → the attempt that lacked a machine and was started again.
  final rerun = <int, int>{};
  final deadline = DateTime.now().add(wait);
  late List<String> problems;
  while (true) {
    final runs = await github.runs(commit);
    problems = checkRuns(runs);
    // Runs whose only unfinished jobs never got a machine.
    final idle = <Map<String, Object?>, List<String>>{};
    for (final run in newestRuns(runs).values) {
      if (run['status'] != 'completed' || run['conclusion'] == 'success') {
        continue;
      }
      final jobs = await github.jobs(run['id'] as int);
      final names = withoutRunner(jobs);
      if (names.isNotEmpty && names.length == unfinished(jobs).length) {
        idle[run] = names;
      }
    }
    // A run started again counts as going until its new attempt finished.
    final going = runs.any(
      (r) =>
          rerun.containsKey(r['id']) &&
          (r['status'] != 'completed' || r['run_attempt'] == rerun[r['id']]),
    );
    final again = [
      if (github.canRerun)
        for (final run in idle.keys)
          if (!rerun.containsKey(run['id'])) run,
    ];
    if (again.isEmpty && !going) {
      problems = [
        for (final p in problems)
          if (!idle.keys.any((r) => p.contains('${r['html_url']}'))) p,
        for (final MapEntry(key: run, value: names) in idle.entries)
          'GitHub ${run['name']}: ${names.join(', ')} bekam keinen Rechner '
              '(kein Fehler im Code) – neu starten: ${run['html_url']}'
              '${github.canRerun ? ' (schon einmal neu gestartet)' : ' (oder GITHUB_RERUN_TOKEN setzen)'}',
      ];
      break;
    }
    for (final run in again) {
      stdout.writeln(
        'GitHub ${run['name']}: ${idle[run]!.join(', ')} bekam keinen '
        'Rechner – neu gestartet',
      );
      await github.rerunFailed(run['id'] as int);
      rerun[run['id'] as int] = run['run_attempt'] as int? ?? 1;
    }
    if (DateTime.now().isAfter(deadline)) {
      problems.add('GitHub: nach ${wait.inMinutes} Minuten noch nicht fertig');
      break;
    }
    await Future<void>.delayed(const Duration(minutes: 1));
  }
  final gitea = await _get(
    Uri.parse('${env['GITEA_API']}/commits/$commit/status'),
    {'authorization': 'token ${env['GITEA_TOKEN']}'},
  );
  problems = [
    ...problems,
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

Future<Map<String, Object?>> _get(Uri uri, Map<String, String> headers) =>
    _send('GET', uri, headers, ok: 200);

Future<Map<String, Object?>> _send(
  String method,
  Uri uri,
  Map<String, String> headers, {
  required int ok,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(minutes: 2));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(minutes: 2));
    if (response.statusCode != ok) {
      stderr.writeln('${uri.host} antwortet ${response.statusCode}');
      exit(69);
    }
    return text.isEmpty ? const {} : (jsonDecode(text) as Map).cast();
  } finally {
    client.close(force: true);
  }
}

class _GitHub {
  _GitHub(this._token, this._rerunToken);

  final String _token;
  final String? _rerunToken;

  bool get canRerun => (_rerunToken ?? '').isNotEmpty;

  Map<String, String> _headers(String token) => {
    'authorization': 'Bearer $token',
    'accept': 'application/vnd.github+json',
  };

  Future<List<Map<String, Object?>>> runs(String commit) async {
    final d = await _get(
      Uri.https('api.github.com', '/repos/$githubRepository/actions/runs', {
        'head_sha': commit,
        'per_page': '100',
      }),
      _headers(_token),
    );
    return [
      for (final run in d['workflow_runs'] as List? ?? const [])
        (run as Map).cast<String, Object?>(),
    ];
  }

  Future<List<Map<String, Object?>>> jobs(int run) async {
    final d = await _get(
      Uri.https(
        'api.github.com',
        '/repos/$githubRepository/actions/runs/$run/jobs',
        {'filter': 'latest', 'per_page': '100'},
      ),
      _headers(_token),
    );
    return [
      for (final job in d['jobs'] as List? ?? const [])
        (job as Map).cast<String, Object?>(),
    ];
  }

  Future<void> rerunFailed(int run) => _send(
    'POST',
    Uri.https(
      'api.github.com',
      '/repos/$githubRepository/actions/runs/$run/rerun-failed-jobs',
    ),
    _headers(_rerunToken!),
    ok: 201,
  );
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
  final newest = newestRuns(runs);
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

/// The newest run of each required workflow, by its path. A rerun keeps
/// its run (and id) and only raises `run_attempt`.
Map<String, Map<String, Object?>> newestRuns(List<Map<String, Object?>> runs) {
  final newest = <String, Map<String, Object?>>{};
  for (final run in runs) {
    final path = run['path'] as String? ?? '';
    if (!requiredWorkflows.contains(path)) continue;
    final known = newest[path];
    if (known == null ||
        '${run['created_at']}'.compareTo('${known['created_at']}') > 0) {
      newest[path] = run;
    }
  }
  return newest;
}

/// The jobs of a run (GitHub's JSON) that did not pass.
List<Map<String, Object?>> unfinished(List<Map<String, Object?>> jobs) => [
  for (final job in jobs)
    if (job['conclusion'] != 'success' && job['conclusion'] != 'skipped') job,
];

/// The names of the jobs GitHub cancelled before any machine took them: no
/// runner, not a single step (2.0.32's macOS build, after 15 minutes).
List<String> withoutRunner(List<Map<String, Object?>> jobs) => [
  for (final job in unfinished(jobs))
    if (job['status'] == 'completed' &&
        job['conclusion'] == 'cancelled' &&
        '${job['runner_name'] ?? ''}'.isEmpty &&
        (job['steps'] as List? ?? const []).isEmpty)
      '${job['name']}',
];

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
