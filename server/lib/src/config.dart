import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

class ServerConfig {
  const ServerConfig({
    this.port = 8765,
    this.dataDir = 'data',
    this.ingressAuth = false,
    this.healthcheck = false,
    this.timeZone = 'Europe/Berlin',
    this.publicUrl,
    this.trustProxy = false,
    this.maxUploadMb = 100,
    this.locationHistoryDays = 7,
    this.maxStorageMb = 5120,
    this.allowPrivateCalendarHosts = false,
    this.keyFile,
    this.tlsPort = 8766,
    this.requireTls = true,
    this.tlsNames = const [],
    this.webDir,
    this.upstream,
    this.upstreamPin,
    this.clientMode = false,
  });

  /// Reads configuration from CLI args, environment and, when running as a
  /// Home Assistant add-on, `/data/options.json`.
  factory ServerConfig.load(List<String> args) {
    final parser = ArgParser()
      ..addOption('port', abbr: 'p')
      ..addOption('data-dir', abbr: 'd')
      ..addFlag(
        'healthcheck',
        negatable: false,
        help: 'Check that a server on --port answers, then exit (for Docker).',
      )
      ..addFlag('help', abbr: 'h', negatable: false);
    final parsed = parser.parse(args);
    if (parsed.flag('help')) {
      stdout.writeln('famio_server [options]\n${parser.usage}');
      exit(0);
    }

    final env = Platform.environment;
    final isAddon = env.containsKey('SUPERVISOR_TOKEN');
    var options = <String, Object?>{};
    final optionsFile = File('/data/options.json');
    if (isAddon && optionsFile.existsSync()) {
      options = (jsonDecode(optionsFile.readAsStringSync()) as Map).cast();
    }

    return ServerConfig(
      port: int.parse(parsed.option('port') ?? env['FAMIO_PORT'] ?? '8765'),
      dataDir:
          parsed.option('data-dir') ??
          env['FAMIO_DATA_DIR'] ??
          (isAddon ? '/data' : 'data'),
      ingressAuth: isAddon && (options['ingress_auth'] as bool? ?? true),
      healthcheck: parsed.flag('healthcheck'),
      timeZone:
          env['FAMIO_TIMEZONE'] ??
          options['timezone'] as String? ??
          _ianaZone(env['TZ']) ??
          'Europe/Berlin',
      publicUrl: _nonEmpty(env['FAMIO_PUBLIC_URL']),
      trustProxy: _flag(env['FAMIO_TRUST_PROXY']),
      maxUploadMb: int.tryParse(env['FAMIO_MAX_UPLOAD_MB'] ?? '') ?? 100,
      locationHistoryDays: _boundedInt(
        env['FAMIO_LOCATION_HISTORY_DAYS'],
        fallback: 7,
        min: 1,
        max: 365,
      ),
      maxStorageMb: int.tryParse(env['FAMIO_MAX_STORAGE_MB'] ?? '') ?? 5120,
      allowPrivateCalendarHosts: _flag(
        env['FAMIO_ALLOW_PRIVATE_CALENDAR_HOSTS'],
      ),
      keyFile: _nonEmpty(env['FAMIO_KEY_FILE']),
      tlsPort: int.tryParse(env['FAMIO_TLS_PORT'] ?? '') ?? 8766,
      // Secure by default. Older installations can deliberately opt out
      // with FAMIO_REQUIRE_TLS=false while their clients are migrated.
      requireTls: _flag(env['FAMIO_REQUIRE_TLS'], defaultValue: true),
      tlsNames: [
        for (final n in (env['FAMIO_TLS_NAMES'] ?? '').split(RegExp(r'[,\s]+')))
          if (n.trim().isNotEmpty) n.trim().toLowerCase(),
      ],
      webDir: _nonEmpty(env['FAMIO_WEB_DIR']),
      // Add-on in client mode: only the sidebar, the family's server runs
      // elsewhere.
      upstream: options['mode'] == 'client'
          ? _nonEmpty(options['server_url'] as String?)
          : _nonEmpty(env['FAMIO_UPSTREAM']),
      clientMode: options['mode'] == 'client',
      upstreamPin: options['mode'] == 'client'
          ? _nonEmpty(options['server_fingerprint'] as String?)
          : _nonEmpty(env['FAMIO_UPSTREAM_FINGERPRINT']),
    );
  }

  /// Folder of the web app; default `web/` next to the server's `bin/`.
  final String? webDir;

  /// Address of the family's Famio server when this one only serves the
  /// Home Assistant sidebar (client mode); null runs the full server.
  final String? upstream;

  /// The add-on is set to client mode (then [upstream] is required).
  final bool clientMode;

  /// Fingerprint of [upstream]'s own certificate (home network server).
  final String? upstreamPin;

  final int port;
  final String dataDir;

  /// Trust Home Assistant ingress user headers from the supervisor proxy.
  final bool ingressAuth;

  /// Only probe a running server instead of starting one.
  final bool healthcheck;

  /// IANA zone of the family, used for calendar feeds (series times) and
  /// imported events without an explicit zone.
  final String timeZone;

  /// Address under which the server is reachable from the internet, e.g.
  /// `https://famio.example.org/`. Google Calendar fetches subscriptions
  /// from Google's servers, so feed links must use this address to work there.
  final String? publicUrl;

  /// Behind a reverse proxy: take the client address from X-Forwarded-For
  /// (for login throttling). Only enable if the port is not reachable
  /// directly, otherwise clients could fake their address.
  final bool trustProxy;

  /// Maximum upload size (documents, photos).
  final int maxUploadMb;

  /// Default retention for precise location history. Admins can override it
  /// in the app; the server still enforces the chosen retention itself.
  final int locationHistoryDays;

  /// Hard storage budget for all uploads of this Famio installation.
  final int maxStorageMb;

  /// Explicit opt-in for CalDAV/ICS servers in the home network.
  final bool allowPrivateCalendarHosts;

  /// Key for encrypting database and files at rest. Keep it outside the
  /// data directory (and its backups); defaults to `<dataDir>/famio.key`.
  final String? keyFile;

  /// HTTPS port with the server's own certificate, for apps in the home
  /// network (0 disables it).
  final int tlsPort;

  /// Refuse unencrypted API access except through a TLS-terminating proxy,
  /// Home Assistant ingress or localhost.
  final bool requireTls;

  /// Extra host names and IP addresses for the HTTPS certificate, e.g. the
  /// server's address in the home network (`FAMIO_TLS_NAMES=192.168.1.5`).
  /// Apple devices only connect to names listed in the certificate.
  final List<String> tlsNames;
}

bool _flag(String? v, {bool defaultValue = false}) {
  if (v == null || v.trim().isEmpty) return defaultValue;
  return const {'1', 'true', 'yes', 'on'}.contains(v.trim().toLowerCase());
}

int _boundedInt(
  String? value, {
  required int fallback,
  required int min,
  required int max,
}) {
  final parsed = int.tryParse(value ?? '');
  return parsed == null || parsed < min || parsed > max ? fallback : parsed;
}

String? _nonEmpty(String? v) => v == null || v.trim().isEmpty ? null : v.trim();

/// `TZ` may also hold POSIX strings like `CET-1CEST`; only accept IANA names.
String? _ianaZone(String? tz) =>
    tz != null && tz.contains('/') && !tz.startsWith(':') ? tz : null;
