import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'api_exception.dart';
import 'i18n.dart';

/// Resolves a host name; [InternetAddress.lookup] outside of tests.
typedef HostLookup = Future<List<InternetAddress>> Function(String host);

/// Validates destinations fetched by the server on a member's behalf.
///
/// Calendar URLs otherwise let an authenticated member probe services in the
/// server's home or container network. Private targets are an explicit
/// deployment opt-in for installations that really host a calendar locally.
///
/// [check] says early and in words what is wrong with an address. Where the
/// server then connects, [client] decides again: it resolves the name once
/// per connection, checks every address and connects to exactly those, so a
/// name that points somewhere else a moment later does not lead elsewhere.
class RemoteUrlPolicy {
  const RemoteUrlPolicy({
    this.allowPrivateNetwork = false,
    this.lookup = InternetAddress.lookup,
  });

  final bool allowPrivateNetwork;

  /// Tests answer without the network, so a disturbed resolver cannot make
  /// them hang.
  final HostLookup lookup;

  /// At most this long for the name server.
  static const lookupTimeout = Duration(seconds: 10);

  /// At most this long for a connection, its TLS handshake included.
  static const connectTimeout = Duration(seconds: 20);

  /// [ApiException.code] when a name could not be resolved: the request
  /// may work later (a disturbed name server), the address is not unsafe.
  static const notFound = 'remote_host_not_found';

  Future<void> check(Uri uri) async {
    if ((!(uri.isScheme('https') ||
            allowPrivateNetwork && uri.isScheme('http'))) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ApiException.badRequest(
        'unsafe_remote_url',
        t(
          'Externe Ziele brauchen eine HTTPS-Adresse ohne Zugangsdaten in der Adresse.',
        ),
      );
    }
    if (allowPrivateNetwork) return;
    await _publicAddresses(uri.host);
  }

  /// An HTTP client that only connects to addresses [check] accepts.
  ///
  /// Without [allowPrivateNetwork], every new connection resolves the name
  /// with [lookup], refuses it when any of its addresses is not public and
  /// connects to one of exactly these addresses; TLS still checks the
  /// certificate against the name. A proxy set up in the environment
  /// (`https_proxy`) connects on its own, as before.
  http.Client client() {
    if (allowPrivateNetwork) return http.Client();
    return IOClient(
      HttpClient()
        ..connectionTimeout = connectTimeout
        ..connectionFactory = _connect,
    );
  }

  Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    if (proxyHost != null && proxyPort != null) {
      return Socket.startConnect(proxyHost, proxyPort);
    }
    return connectToAddresses(uri, await _publicAddresses(uri.host));
  }

  /// The addresses of [host]; throws if one of them is not public.
  Future<List<InternetAddress>> _publicAddresses(String host) async {
    var name = host.toLowerCase();
    while (name.endsWith('.')) {
      name = name.substring(0, name.length - 1);
    }
    if (name == 'localhost' || name.endsWith('.localhost')) _blocked(host);
    final literal = InternetAddress.tryParse(name);
    final List<InternetAddress> addresses;
    if (literal != null) {
      addresses = [literal];
    } else {
      try {
        addresses = await lookup(host).timeout(lookupTimeout);
      } on SocketException {
        _notFound(host);
      } on TimeoutException {
        _notFound(host);
      }
    }
    if (addresses.isEmpty) _notFound(host);
    if (!addresses.every(isPublic)) _blocked(host);
    return addresses;
  }

  /// Whether [a] is an address on the internet. Not: this network
  /// (0.0.0.0/8), loopback, link-local, private and shared (CGNAT)
  /// networks, IETF protocol and benchmark ranges, multicast, reserved and
  /// broadcast addresses; IPv6 unspecified, loopback, unique local,
  /// link-local, site-local, multicast, discard, Teredo and local NAT64.
  /// IPv6 forms that carry an IPv4 address (mapped, compatible, NAT64,
  /// 6to4) count as that IPv4 address, in every way of writing them.
  static bool isPublic(InternetAddress a) {
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4) return _publicV4(b);
    if (a.type != InternetAddressType.IPv6 || b.length != 16) return false;
    bool zeros(int from, int to) => b.sublist(from, to).every((x) => x == 0);
    // ::/96 (unspecified, loopback, IPv4-compatible) and ::ffff:0:0/96.
    if (zeros(0, 10) &&
        ((b[10] == 0 && b[11] == 0) || (b[10] == 0xff && b[11] == 0xff))) {
      return _publicV4(b.sublist(12));
    }
    // NAT64 (64:ff9b::/96) reaches the IPv4 address in its last bytes;
    // the local-use prefix 64:ff9b:1::/48 stays in the operator's network.
    if (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b) {
      if (zeros(4, 12)) return _publicV4(b.sublist(12));
      if (b[4] == 0x00 && b[5] == 0x01) return false;
    }
    // 6to4 (2002::/16): the IPv4 address follows the prefix.
    if (b[0] == 0x20 && b[1] == 0x02) return _publicV4(b.sublist(2, 6));
    // Teredo (2001::/32) tunnels to an address nobody here can check.
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0 && b[3] == 0) return false;
    // Discard-only (100::/64).
    if (b[0] == 0x01 && b[1] == 0 && zeros(2, 8)) return false;
    if ((b[0] & 0xfe) == 0xfc) return false; // fc00::/7, unique local
    if (b[0] == 0xfe && (b[1] & 0x80) == 0x80) return false; // fe80::/9
    if (b[0] == 0xff) return false; // multicast
    return true;
  }

  static bool _publicV4(List<int> b) {
    final (x, y, z) = (b[0], b[1], b[2]);
    return !(x == 0 || // this network
        x == 10 ||
        x == 127 ||
        (x == 100 && y >= 64 && y <= 127) || // shared (CGNAT), Tailscale
        (x == 169 && y == 254) ||
        (x == 172 && y >= 16 && y <= 31) ||
        (x == 192 && y == 0 && z == 0) || // IETF protocol assignments
        (x == 192 && y == 168) ||
        (x == 198 && (y == 18 || y == 19)) || // benchmarking
        x >= 224); // multicast, reserved, broadcast
  }

  Never _blocked(String host) => throw ApiException.badRequest(
    'unsafe_remote_url',
    t(
      'Die Adresse {host} zeigt in ein privates Netzwerk. Lokale Ziele müssen vom Server ausdrücklich freigegeben werden.',
      {'host': host},
    ),
  );

  Never _notFound(String host) => throw ApiException(
    502,
    notFound,
    t('Die Adresse {host} wurde nicht gefunden.', {'host': host}),
  );
}

/// Starts a TCP connection; [Socket.startConnect] outside of tests.
typedef StartConnect =
    Future<ConnectionTask<Socket>> Function(InternetAddress address, int port);

/// How long an address may stay silent before the next one is tried as
/// well, as the SDK does for the names it resolves itself (RFC 8305).
const connectionStagger = Duration(milliseconds: 250);

/// Opens a connection for [uri] to the first of [addresses] that answers,
/// for `https` with TLS for the name of [uri] (certificate check and SNI).
///
/// Only [addresses] are used, in their order. The next one starts when the
/// attempt before it fails or has not answered after [stagger]; the first
/// TCP connection wins and every other attempt is cancelled, so an address
/// that never answers (a broken IPv6 route) does not use up the time for
/// the connection. TLS runs on the winner only. When all fail, the first
/// failure is thrown. Cancelling the returned task stops every attempt.
///
/// [context]: trusted certificates other than the system's (tests).
Future<ConnectionTask<Socket>> connectToAddresses(
  Uri uri,
  List<InternetAddress> addresses, {
  SecurityContext? context,
  Duration stagger = connectionStagger,
  StartConnect startConnect = Socket.startConnect,
}) async {
  final port = uri.port;
  final won = Completer<Socket>();
  // Cancelling after [connect] gave up (no address) completes [won] with
  // nobody waiting; that must not surface as an uncaught error.
  won.future.ignore();
  final pending = <ConnectionTask<Socket>>{};
  var next = 0;
  var running = 0;
  var cancelled = false;
  Timer? timer;
  (Object, StackTrace)? failure;
  Socket? open;

  bool over() => cancelled || won.isCompleted;

  void stopAttempts() {
    timer?.cancel();
    for (final task in pending.toList()) {
      task.cancel();
    }
    pending.clear();
  }

  late final void Function() start;

  void failed(Object error, StackTrace trace) {
    running--;
    failure ??= (error, trace);
    if (over()) return;
    if (next < addresses.length) {
      start();
    } else if (running == 0) {
      won.completeError(failure!.$1, failure!.$2);
    }
  }

  void attempt(ConnectionTask<Socket> task) {
    if (over()) {
      // Not needed any more.
      running--;
      task.cancel();
      task.socket.then((socket) => socket.destroy(), onError: (_) {});
      return;
    }
    pending.add(task);
    task.socket.then(
      (socket) {
        pending.remove(task);
        running--;
        if (over()) {
          socket.destroy();
          return;
        }
        open = socket;
        stopAttempts();
        won.complete(socket);
      },
      onError: (Object e, StackTrace s) {
        pending.remove(task);
        failed(e, s);
      },
    );
  }

  start = () {
    timer?.cancel();
    if (over() || next >= addresses.length) return;
    final address = addresses[next++];
    running++;
    if (next < addresses.length) timer = Timer(stagger, start);
    Future.sync(
      () => startConnect(address, port),
    ).then(attempt, onError: failed);
  };

  Future<Socket> connect() async {
    if (addresses.isEmpty) {
      throw SocketException('No address to connect to', port: port);
    }
    start();
    final socket = await won.future;
    if (cancelled) {
      socket.destroy();
      throw SocketException('Connection cancelled', port: port);
    }
    if (!uri.isScheme('https')) return socket;
    try {
      return await SecureSocket.secure(
        socket,
        host: uri.host,
        context: context,
      );
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  return ConnectionTask.fromSocket(connect(), () {
    if (cancelled) return;
    cancelled = true;
    stopAttempts();
    open?.destroy();
    if (!won.isCompleted) {
      won.completeError(SocketException('Connection cancelled', port: port));
    }
  });
}
