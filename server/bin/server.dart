import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/timezone.dart' as tz;

Future<void> main(List<String> args) async {
  final config = ServerConfig.load(args);
  if (config.healthcheck) exit(await _healthcheck(config.port));
  _privateFiles();
  Directory(config.dataDir).createSync(recursive: true);
  final webApp = WebApp.locate(config.webDir);
  if (config.clientMode && config.upstream == null) {
    stderr.writeln(
      'FEHLER: Betriebsart „client“ braucht die Server-Adresse (server_url) '
      'eures Famio-Servers in den Add-on-Optionen.',
    );
    exit(78); // EX_CONFIG
  }
  if (config.upstream case final upstream?) {
    return _runPanelProxy(config, Uri.parse(upstream), webApp);
  }

  // Encryption at rest: the key should live outside the data directory, so
  // that backups of the data alone are useless to a thief.
  final keyPath = config.keyFile ?? p.join(config.dataDir, 'famio.key');
  final keySeparate = !p.isWithin(
    p.absolute(config.dataDir),
    p.absolute(keyPath),
  );
  final String key;
  final Database db;
  try {
    key = loadOrCreateDataKey(keyPath, dataDir: config.dataDir);
    db = openFamioDatabase(p.join(config.dataDir, 'famio.db'), hexKey: key);
  } on DataKeyException catch (e) {
    stderr.writeln('FEHLER: $e');
    exit(78); // EX_CONFIG
  }

  final tls = config.tlsPort > 0
      ? ServerTls(config.dataDir, names: config.tlsNames)
      : null;
  FamioServerApp.initTimeZones();
  final location = _location(config.timeZone);
  final app = FamioServerApp(
    db: db,
    location: location,
    dataDir: config.dataDir,
    publicUrl: config.publicUrl,
    ingressAuth: config.ingressAuth,
    trustProxy: config.trustProxy,
    maxUploadMb: config.maxUploadMb,
    dataKey: key,
    keySeparate: keySeparate,
    requireTls: config.requireTls,
    tlsPort: tls == null ? null : config.tlsPort,
    tls: tls,
    webApp: webApp,
    auditLog: (line) =>
        stdout.writeln('${DateTime.now().toIso8601String()} $line'),
  )..startBackgroundJobs();

  final handler = const Pipeline()
      .addMiddleware(logRequests(logger: _redactedLog))
      .addHandler(app.handler);
  // No "X-Powered-By" header: it only tells attackers what runs here.
  final server = await io.serve(
    handler,
    InternetAddress.anyIPv4,
    config.port,
    poweredByHeader: null,
  );
  Future<HttpServer> serveTls(TlsIdentity identity) => io.serve(
    handler,
    InternetAddress.anyIPv4,
    config.tlsPort,
    securityContext: identity.context,
    poweredByHeader: null,
  );
  var secure = tls == null ? null : await serveTls(tls.identity);
  if (tls != null) {
    // New host name or renewal: continue with the new certificate.
    tls.renewed.listen((identity) async {
      await secure?.close();
      secure = await serveTls(identity);
      stdout.writeln('HTTPS-Zertifikat erneuert (gleicher Fingerabdruck).');
    });
    Timer.periodic(const Duration(days: 1), (_) => tls.renewIfDue());
  }
  stdout.writeln(
    'Famio server $serverVersion listening on :${server.port} '
    '${secure == null ? '' : '(https :${secure!.port}) '}'
    '(data: ${p.absolute(config.dataDir)}, time zone: ${app.location.name}, '
    'ingress auth: ${config.ingressAuth}, trust proxy: ${config.trustProxy}, '
    'require tls: ${config.requireTls})',
  );
  stdout.writeln(
    'Daten verschlüsselt (Schlüssel: ${p.absolute(keyPath)}). '
    'Schlüsseldatei getrennt von den Daten sichern!',
  );
  if (!keySeparate) {
    stdout.writeln(
      'WARNUNG: Der Schlüssel liegt im Datenordner – Backups davon enthalten '
      'Daten und Schlüssel. FAMIO_KEY_FILE auf einen anderen Ort setzen.',
    );
  }
  if (tls != null) {
    stdout.writeln(
      'HTTPS-Zertifikat (Fingerabdruck zum Vergleich in der App):\n'
      '  ${tls.fingerprint}',
    );
  }
  if (app.setupCode case final code?) {
    stdout.writeln(
      '\n  Noch kein Konto angelegt. Einrichtungscode für die App: $code\n'
      '  (Nur nötig, wenn die Einrichtung über einen Reverse-Proxy oder das\n'
      '  Internet erfolgt; im Heimnetz direkt auf Port ${config.port} nicht.)\n',
    );
  }

  final signals = [
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ];
  for (final signal in signals) {
    signal.watch().listen((_) async {
      await server.close();
      await secure?.close();
      await app.close();
      exit(0);
    });
  }
}

/// Home Assistant add-on in client mode: only the sidebar, connected to the
/// family's Famio server at [upstream].
Future<void> _runPanelProxy(
  ServerConfig config,
  Uri upstream,
  WebApp? webApp,
) async {
  final proxy = PanelProxy(
    upstream: upstream,
    pin: config.upstreamPin,
    dataDir: config.dataDir,
    webApp: webApp,
  );
  final handler = const Pipeline()
      .addMiddleware(logRequests(logger: _redactedLog))
      .addHandler(proxy.handler);
  final server = await io.serve(
    handler,
    InternetAddress.anyIPv4,
    config.port,
    poweredByHeader: null,
  );
  stdout.writeln(
    'Famio $serverVersion für die Home-Assistant-Seitenleiste auf '
    ':${server.port}, verbunden mit $upstream'
    '${webApp == null ? ' (WARNUNG: Web-App fehlt)' : ''}',
  );
  final signals = [
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ];
  for (final signal in signals) {
    signal.watch().listen((_) async {
      await server.close();
      proxy.close();
      exit(0);
    });
  }
}

/// Exit code 0 if the server on [port] answers `/api/health`.
Future<int> _healthcheck(int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.get('127.0.0.1', port, '/api/health');
    final response = await request.close().timeout(const Duration(seconds: 3));
    await response.drain<void>();
    return response.statusCode == 200 ? 0 : 1;
  } catch (e) {
    stderr.writeln('healthcheck failed: $e');
    return 1;
  } finally {
    client.close(force: true);
  }
}

tz.Location _location(String name) {
  try {
    return tz.getLocation(name);
  } on tz.LocationNotFoundException {
    stderr.writeln('Unknown time zone "$name", using Europe/Berlin.');
    return tz.getLocation('Europe/Berlin');
  }
}

/// Request log without secrets: calendar feed tokens are credentials, and
/// query strings carry file names (e.g. of medical documents).
void _redactedLog(String message, bool isError) {
  final safe = message
      .replaceAll(RegExp(r'/ical/[A-Za-z0-9_-]+'), '/ical/***')
      .replaceAll(RegExp(r'\?\S*'), '');
  (isError ? stderr : stdout).writeln(safe);
}

/// Database, uploads and thumbnails hold family and health data: files the
/// server creates are readable by its own user only (umask 077).
void _privateFiles() {
  if (Platform.isWindows) return;
  try {
    DynamicLibrary.process()
        .lookupFunction<Uint32 Function(Uint32), int Function(int)>('umask')(
      0x3f, // 077
    );
  } catch (e) {
    stderr.writeln('Could not set umask: $e');
  }
}
