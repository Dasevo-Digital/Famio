import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';

/// The server's own TLS identity for HTTPS in the home network.
///
/// A small local certificate authority (valid 20 years) signs the server
/// certificate. Apple devices only accept server certificates that name the
/// host and are valid for at most 825 days, so the server certificate is
/// renewed from time to time – always with the same key. Apps pin that key
/// ([fingerprint]); Apple Calendar trusts the authority ([caPem]) through a
/// configuration profile.
class TlsIdentity {
  const TlsIdentity({required this.certPem, required this.keyPem, this.caPem});

  /// The server certificate.
  final String certPem;
  final String keyPem;

  /// The local certificate authority (null for an older self-signed cert).
  final String? caPem;

  /// SHA-256 of the server key, as the apps display and pin it.
  String get fingerprint => formatFingerprint(
    sha256.convert(subjectPublicKeyInfo(derOf(certPem))).bytes,
  );

  SecurityContext get context => SecurityContext()
    // Only the server certificate: apps pin its key (Dart reports the
    // topmost untrusted certificate, which would otherwise be the
    // authority), and Apple devices know the authority from the profile.
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  /// Validity of new server certificates (Apple: at most 825 days).
  static const certDays = 800;

  /// Renew the server certificate this long before it expires.
  static const renewBefore = Duration(days: 60);

  /// Host names and addresses always in the certificate.
  static List<String> defaultNames() => {
    'localhost',
    '127.0.0.1',
    '::1',
    'homeassistant.local',
    if (Platform.localHostname.isNotEmpty) ...[
      Platform.localHostname.toLowerCase(),
      if (!Platform.localHostname.contains('.'))
        '${Platform.localHostname.toLowerCase()}.local',
    ],
  }.toList();

  /// Loads the identity from [dir], creating or renewing what is missing:
  /// the authority once, the server certificate when it expires soon, does
  /// not cover [names] or was not issued by the authority.
  static TlsIdentity loadOrCreate(
    String dir, {
    List<String> names = const [],
    DateTime? now,
  }) {
    now ??= DateTime.now();
    final wanted = {...defaultNames(), ...names}.toList()..sort();
    final keyFile = File('$dir/tls-key.pem');
    final certFile = File('$dir/tls-cert.pem');
    final infoFile = File('$dir/tls-cert.json');
    final caKeyFile = File('$dir/tls-ca-key.pem');
    final caFile = File('$dir/tls-ca.pem');

    // The server key stays the same across renewals (apps pin it).
    final ECPrivateKey key;
    if (keyFile.existsSync()) {
      key = CryptoUtils.ecPrivateKeyFromPem(keyFile.readAsStringSync());
    } else {
      key = CryptoUtils.generateEcKeyPair().privateKey as ECPrivateKey;
      _writePrivate(keyFile, CryptoUtils.encodeEcPrivateKeyToPem(key));
    }

    final ECPrivateKey caKey;
    final String caPem;
    if (caKeyFile.existsSync() && caFile.existsSync()) {
      caKey = CryptoUtils.ecPrivateKeyFromPem(caKeyFile.readAsStringSync());
      caPem = caFile.readAsStringSync();
    } else {
      caKey = CryptoUtils.generateEcKeyPair().privateKey as ECPrivateKey;
      caPem = _pem(
        _certificate(
          subject: 'Famio Heimserver',
          issuer: 'Famio Heimserver',
          publicKey: _publicKey(caKey),
          signer: caKey,
          from: now,
          until: now.add(const Duration(days: 20 * 365)),
          authority: true,
        ),
      );
      _writePrivate(caKeyFile, CryptoUtils.encodeEcPrivateKeyToPem(caKey));
      caFile.writeAsStringSync(caPem, flush: true);
      if (infoFile.existsSync()) infoFile.deleteSync();
    }

    Map<String, Object?>? info;
    try {
      info = (jsonDecode(infoFile.readAsStringSync()) as Map).cast();
    } catch (_) {
      // Older self-signed certificate or none yet.
    }
    final until = DateTime.tryParse(info?['notAfter'] as String? ?? '');
    final current =
        certFile.existsSync() &&
        until != null &&
        now.isBefore(until.subtract(renewBefore)) &&
        (info?['names'] as List?)?.join(',') == wanted.join(',');
    if (current) {
      return TlsIdentity(
        certPem: certFile.readAsStringSync(),
        keyPem: keyFile.readAsStringSync(),
        caPem: caPem,
      );
    }

    final notAfter = now.add(const Duration(days: certDays));
    final certPem = _pem(
      _certificate(
        subject: 'Famio',
        issuer: 'Famio Heimserver',
        publicKey: _publicKey(key),
        signer: caKey,
        issuerKey: _publicKey(caKey),
        from: now.subtract(const Duration(hours: 1)),
        until: notAfter,
        names: wanted,
      ),
    );
    certFile.writeAsStringSync(certPem, flush: true);
    infoFile.writeAsStringSync(
      jsonEncode({
        'names': wanted,
        'notAfter': notAfter.toUtc().toIso8601String(),
      }),
      flush: true,
    );
    return TlsIdentity(
      certPem: certPem,
      keyPem: keyFile.readAsStringSync(),
      caPem: caPem,
    );
  }

  // Only readable by the server: it runs with umask 077.
  static void _writePrivate(File file, String pem) =>
      file.writeAsStringSync(pem, flush: true);
}

List<int> derOf(String pem) => base64.decode(
  pem
      .split(RegExp(r'\r?\n'))
      .where((l) => !l.startsWith('-----'))
      .join()
      .replaceAll(RegExp(r'\s'), ''),
);

String _pem(List<int> der) {
  final b64 = base64.encode(der);
  final lines = [
    for (var i = 0; i < b64.length; i += 64)
      b64.substring(i, min(i + 64, b64.length)),
  ];
  return '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n'
      '-----END CERTIFICATE-----\n';
}

ECPublicKey _publicKey(ECPrivateKey key) =>
    ECPublicKey(key.parameters!.G * key.d, key.parameters);

// --- minimal DER encoding of X.509 certificates -----------------------------

List<int> _tlv(int tag, List<int> content) {
  final n = content.length;
  final length = n < 0x80
      ? [n]
      : n < 0x100
      ? [0x81, n]
      : [0x82, n >> 8, n & 0xff];
  return [tag, ...length, ...content];
}

List<int> _seq(List<List<int>> items) =>
    _tlv(0x30, [for (final i in items) ...i]);

List<int> _oid(String dotted) {
  final parts = dotted.split('.').map(int.parse).toList();
  final bytes = <int>[parts[0] * 40 + parts[1]];
  for (final part in parts.skip(2)) {
    final chunk = <int>[part & 0x7f];
    var v = part >> 7;
    while (v > 0) {
      chunk.insert(0, (v & 0x7f) | 0x80);
      v >>= 7;
    }
    bytes.addAll(chunk);
  }
  return _tlv(0x06, bytes);
}

List<int> _integer(BigInt value) {
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  if (bytes.isEmpty || bytes.first & 0x80 != 0) bytes.insert(0, 0);
  return _tlv(0x02, bytes);
}

List<int> _name(String commonName) => _seq([
  _tlv(0x31, _seq([_oid('2.5.4.3'), _tlv(0x0C, utf8.encode(commonName))])),
]);

List<int> _time(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  // UTCTime until 2049, GeneralizedTime after (RFC 5280).
  return u.year < 2050
      ? _tlv(
          0x17,
          ascii.encode(
            '${two(u.year % 100)}${two(u.month)}${two(u.day)}'
            '${two(u.hour)}${two(u.minute)}${two(u.second)}Z',
          ),
        )
      : _tlv(
          0x18,
          ascii.encode(
            '${u.year}${two(u.month)}${two(u.day)}'
            '${two(u.hour)}${two(u.minute)}${two(u.second)}Z',
          ),
        );
}

List<int> _spki(ECPublicKey key) => _seq([
  _seq([_oid('1.2.840.10045.2.1'), _oid('1.2.840.10045.3.1.7')]),
  _tlv(0x03, [0, ...key.Q!.getEncoded(false)]),
]);

List<int> _keyId(ECPublicKey key) =>
    sha1.convert(key.Q!.getEncoded(false)).bytes;

List<int> _extension(String oid, List<int> value, {bool critical = false}) =>
    _seq([
      _oid(oid),
      if (critical) _tlv(0x01, [0xff]),
      _tlv(0x04, value),
    ]);

List<int> _certificate({
  required String subject,
  required String issuer,
  required ECPublicKey publicKey,
  required ECPrivateKey signer,
  required DateTime from,
  required DateTime until,
  ECPublicKey? issuerKey,
  bool authority = false,
  List<String> names = const [],
}) {
  final random = Random.secure();
  final serial = BigInt.parse(
    [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join(),
    radix: 16,
  );
  final algorithm = _seq([_oid('1.2.840.10045.4.3.2')]); // ecdsa-with-SHA256
  final extensions = <List<int>>[
    _extension(
      '2.5.29.19', // basicConstraints
      authority
          ? _seq([
              _tlv(0x01, [0xff]),
              _integer(BigInt.zero),
            ])
          : _seq([]),
      critical: true,
    ),
    _extension(
      '2.5.29.15', // keyUsage: keyCertSign+cRLSign or digitalSignature
      authority ? _tlv(0x03, [1, 0x06]) : _tlv(0x03, [7, 0x80]),
      critical: true,
    ),
    _extension('2.5.29.14', _tlv(0x04, _keyId(publicKey))), // subjectKeyId
    if (!authority) ...[
      _extension('2.5.29.37', _seq([_oid('1.3.6.1.5.5.7.3.1')])), // serverAuth
      _extension(
        '2.5.29.35', // authorityKeyId
        _seq([_tlv(0x80, _keyId(issuerKey!))]),
      ),
      _extension(
        '2.5.29.17', // subjectAltName
        _seq([
          for (final name in names)
            if (InternetAddress.tryParse(name) case final ip?)
              _tlv(0x87, ip.rawAddress)
            else
              _tlv(0x82, ascii.encode(name)),
        ]),
      ),
    ],
  ];
  final tbs = _seq([
    _tlv(0xA0, _integer(BigInt.two)), // v3
    _integer(serial),
    algorithm,
    _name(issuer),
    _seq([_time(from), _time(until)]),
    _name(subject),
    _spki(publicKey),
    _tlv(0xA3, _seq(extensions)),
  ]);
  final signature = X509Utils.eccSign(
    Uint8List.fromList(tbs),
    signer,
    'SHA-256',
  );
  return _seq([
    tbs,
    algorithm,
    _tlv(0x03, [
      0,
      ..._seq([_integer(signature.r), _integer(signature.s)]),
    ]),
  ]);
}

/// The running server's TLS identity: adds host names on demand (e.g. the
/// address an iPhone uses in the home network) and renews the certificate
/// in time. Listeners follow [renewed] to switch to the new certificate.
class ServerTls {
  ServerTls(this.dir, {List<String> names = const []}) : _configured = names {
    identity = TlsIdentity.loadOrCreate(dir, names: _names);
  }

  final String dir;
  final List<String> _configured;
  late TlsIdentity identity;
  final _renewed = StreamController<TlsIdentity>.broadcast();

  /// A new certificate is in use.
  Stream<TlsIdentity> get renewed => _renewed.stream;

  String get fingerprint => identity.fingerprint;

  File get _learnedFile => File('$dir/tls-names.json');

  List<String> get _learned {
    try {
      return [
        for (final n in jsonDecode(_learnedFile.readAsStringSync()) as List)
          n as String,
      ];
    } catch (_) {
      return const [];
    }
  }

  List<String> get _names => [..._configured, ..._learned];

  /// Whether the certificate names [host].
  bool covers(String host) {
    final wanted = _normalize(host);
    return {
      ...TlsIdentity.defaultNames(),
      ..._names,
    }.map(_normalize).contains(wanted);
  }

  /// Adds [host] to the certificate (kept across restarts).
  void addName(String host) {
    if (covers(host)) return;
    final learned = {..._learned, _normalize(host)}.toList()..sort();
    _learnedFile.writeAsStringSync(jsonEncode(learned), flush: true);
    _reload();
  }

  /// Renews the certificate when it expires soon (called daily).
  void renewIfDue() => _reload();

  void _reload() {
    final before = identity.certPem;
    identity = TlsIdentity.loadOrCreate(dir, names: _names);
    if (identity.certPem != before) _renewed.add(identity);
  }

  static String _normalize(String host) {
    final h = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
    return InternetAddress.tryParse(h)?.address ?? h;
  }
}
