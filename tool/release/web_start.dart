// Starts the web app of a release once in a headless Firefox (WebDriver
// BiDi, own empty profile) and checks that it renders without errors:
//
//   dart tool/release/web_start.dart <app url>
//
// Prints "web start: ok" or the errors and exits with 1. Problems of a
// finished build (a part that does not load, a JS error at start) show
// neither in tests nor in debug builds; Android 2.0.9 stayed white for
// such a reason. FIREFOX overrides the browser binary.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final url = args.isEmpty ? 'http://localhost:18765/app/' : args.first;
  final firefox =
      Platform.environment['FIREFOX'] ??
      '/Applications/Firefox.app/Contents/MacOS/firefox';
  if (!File(firefox).existsSync()) {
    stdout.writeln('web start: Firefox fehlt ($firefox)');
    exit(1);
  }
  final profile = await Directory.systemTemp.createTemp('famio-web-start');
  final port = 9300 + DateTime.now().millisecond % 500;
  final browser = await Process.start(firefox, [
    '-headless',
    '-no-remote',
    '-profile',
    profile.path,
    '--remote-debugging-port',
    '$port',
  ]);
  browser.stdout.drain<void>();
  browser.stderr.drain<void>();
  var code = 1;
  try {
    code = await _check(url, port);
  } on Object catch (e) {
    stdout.writeln('web start: $e');
  } finally {
    browser.kill();
    await browser.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => 0,
    );
    await profile.delete(recursive: true);
  }
  exit(code);
}

Future<int> _check(String url, int port) async {
  WebSocket? ws;
  for (var i = 0; i < 60 && ws == null; i++) {
    try {
      ws = await WebSocket.connect('ws://127.0.0.1:$port/session');
    } on Object {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  if (ws == null) throw 'Firefox antwortet nicht';
  var id = 0;
  final waiting = <int, Completer<Map>>{};
  final errors = <String>[];
  ws.listen((m) {
    final msg = jsonDecode(m as String) as Map;
    if (msg['id'] case final int i) {
      waiting.remove(i)?.complete(msg);
    } else if (msg['method'] == 'log.entryAdded') {
      final entry = msg['params'] as Map;
      if (entry['level'] == 'error') errors.add('${entry['text']}');
    }
  });
  Future<Map> send(String method, Map params) {
    final c = Completer<Map>();
    waiting[++id] = c;
    ws!.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return c.future.timeout(const Duration(seconds: 60));
  }

  await send('session.new', {'capabilities': {}});
  await send('session.subscribe', {
    'events': ['log.entryAdded'],
  });
  final tree = await send('browsingContext.getTree', {});
  final context =
      (((tree['result'] as Map)['contexts'] as List).first as Map)['context'];
  await send('browsingContext.navigate', {
    'context': context,
    'url': url,
    'wait': 'complete',
  });
  // Rendered: Flutter put its view into the page and drew into it.
  var rendered = false;
  for (var i = 0; i < 40 && !rendered; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final r = await send('script.evaluate', {
      'expression':
          "!!document.querySelector('flutter-view canvas, flt-glass-pane, "
          "flutter-view flt-scene-host')",
      'target': {'context': context},
      'awaitPromise': false,
    });
    rendered = ((r['result'] as Map?)?['result'] as Map?)?['value'] == true;
  }
  // Errors after the first frame (deferred work, the connect screen).
  await Future<void>.delayed(const Duration(seconds: 3));
  await send('session.end', {});
  await ws.close();
  if (!rendered) errors.insert(0, 'Web-App zeichnet nichts');
  if (errors.isEmpty) {
    stdout.writeln('web start: ok');
    return 0;
  }
  for (final e in errors.take(5)) {
    stdout.writeln('web start: $e');
  }
  return 1;
}
