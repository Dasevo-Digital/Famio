import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

/// Set on requests that arrived on Famio's own HTTPS port (see [overTls]).
/// The scheme of a request cannot tell: dart:io takes it from an
/// `X-Forwarded-Proto` header when there is one, whoever sent it.
const tlsConnectionKey = 'famio.tls';

/// [handler] for a listener with TLS: its requests are encrypted.
Handler overTls(Handler handler) =>
    (request) => handler(request.change(context: {tlsConnectionKey: true}));

/// Determines the client address, honouring `X-Forwarded-For` only when the
/// server runs behind a trusted reverse proxy (e.g. Nginx Proxy Manager).
class ClientAddress {
  const ClientAddress({
    required this.trustProxy,
    this.proxies = const [],
    this.onIgnored,
  });

  final bool trustProxy;

  /// The proxies whose forwarded headers count (`FAMIO_TRUSTED_PROXIES`).
  /// Empty: this computer and the private networks (home network, Docker,
  /// Tailscale) – a proxy is practically always there, so a mistakenly
  /// open port does not let the whole internet fake addresses.
  final List<AddressRange> proxies;

  /// Told about forwarded headers from a peer that is no trusted proxy
  /// (they are ignored), for a hint in the log.
  final void Function(String peer)? onIgnored;

  /// Whether [request] came through a trusted reverse proxy, so its
  /// `X-Forwarded-*` headers count. Requests without a peer (only within
  /// the process, never over the network) do not.
  bool viaProxy(Request request) {
    if (!trustProxy) return false;
    final peer = _peer(request);
    if (peer == null) return false;
    final trusted = proxies.isEmpty
        ? isPrivate(peer)
        : proxies.any((r) => r.contains(peer));
    if (!trusted && _forwards(request)) onIgnored?.call(peer.address);
    return trusted;
  }

  /// Whether a proxy in front of Famio says the client connected with
  /// HTTPS (`X-Forwarded-Proto: https`). With [trustProxy] only the
  /// [viaProxy] ones count; without it one in the private network does too
  /// (Home Assistant with the Nginx Proxy Manager add-on), never a peer on
  /// the internet: what it claims proves nothing.
  bool forwardedHttps(Request request) {
    if (request.headers['x-forwarded-proto']?.toLowerCase() != 'https') {
      return false;
    }
    if (trustProxy) return viaProxy(request);
    final peer = _peer(request);
    return peer != null && isPrivate(peer);
  }

  /// Behind the proxy, the address is the *last* `X-Forwarded-For` entry:
  /// the proxy appends the peer it saw, while everything before it comes
  /// from the client and may be made up. `X-Real-IP` is only a fallback,
  /// as some proxies pass a client's own value through unchanged.
  String of(Request request) {
    if (viaProxy(request)) {
      final hops = [
        for (final hop
            in request.headers['x-forwarded-for']?.split(',') ??
                const <String>[])
          if (hop.trim().isNotEmpty) hop.trim(),
      ];
      if (hops.isNotEmpty) return hops.last;
      final real = request.headers['x-real-ip']?.trim();
      if (real != null && real.isNotEmpty) return real;
    }
    return _peer(request)?.address ?? 'unknown';
  }

  /// True for requests from the local network that did not pass a proxy.
  bool isLocalDirect(Request request) {
    if (_forwards(request)) return false;
    final peer = _peer(request);
    return peer != null && isPrivate(peer);
  }

  static bool _forwards(Request request) =>
      request.headers.containsKey('x-forwarded-for') ||
      request.headers.containsKey('x-forwarded-proto') ||
      request.headers.containsKey('x-real-ip') ||
      request.headers.containsKey('forwarded');

  static InternetAddress? _peer(Request request) =>
      (request.context['shelf.io.connection_info'] as HttpConnectionInfo?)
          ?.remoteAddress;

  static bool isPrivate(InternetAddress a) {
    if (a.isLoopback || a.isLinkLocal) return true;
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4) {
      return b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127); // CGNAT, e.g. Tailscale
    }
    // IPv6 unique local (fc00::/7) and IPv4-mapped private addresses.
    if ((b[0] & 0xfe) == 0xfc) return true;
    final mapped =
        b.sublist(0, 12).every((x) => x == 0) ||
        (b.sublist(0, 10).every((x) => x == 0) &&
            b[10] == 0xff &&
            b[11] == 0xff);
    return mapped && isPrivate(InternetAddress.fromRawAddress(b.sublist(12)));
  }
}

/// One address or a network in CIDR notation (`192.168.10.50`,
/// `172.16.0.0/12`, `fd00::/8`), as in `FAMIO_TRUSTED_PROXIES`.
class AddressRange {
  AddressRange._(this._bytes, this.prefix);

  final List<int> _bytes;

  /// The number of leading bits that must match.
  final int prefix;

  /// The range, or null if [text] is none.
  static AddressRange? tryParse(String text) {
    final parts = text.trim().split('/');
    if (parts.length > 2) return null;
    final address = InternetAddress.tryParse(parts.first);
    if (address == null) return null;
    final bytes = address.rawAddress;
    final bits = bytes.length * 8;
    final prefix = parts.length == 2 ? int.tryParse(parts[1]) : bits;
    if (prefix == null || prefix < 0 || prefix > bits) return null;
    return AddressRange._(bytes, prefix);
  }

  /// The ranges in a list separated by commas or spaces, and the entries
  /// that are none.
  static (List<AddressRange>, List<String>) parseList(String? text) {
    final ranges = <AddressRange>[];
    final invalid = <String>[];
    for (final entry in (text ?? '').split(RegExp(r'[,\s]+'))) {
      if (entry.isEmpty) continue;
      switch (tryParse(entry)) {
        case final range?:
          ranges.add(range);
        case null:
          invalid.add(entry);
      }
    }
    return (ranges, invalid);
  }

  bool contains(InternetAddress address) {
    var b = address.rawAddress;
    // An IPv4 peer on a dual-stack socket arrives as ::ffff:a.b.c.d.
    if (b.length == 16 && _bytes.length == 4 && _mapped(b)) {
      b = b.sublist(12);
    }
    if (b.length != _bytes.length) return false;
    for (var bit = 0; bit < prefix; bit += 8) {
      final left = prefix - bit;
      final mask = left >= 8 ? 0xff : (0xff << (8 - left)) & 0xff;
      if ((b[bit ~/ 8] & mask) != (_bytes[bit ~/ 8] & mask)) return false;
    }
    return true;
  }

  static bool _mapped(List<int> b) =>
      b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;

  @override
  String toString() {
    final address = InternetAddress.fromRawAddress(Uint8List.fromList(_bytes));
    return prefix == _bytes.length * 8
        ? address.address
        : '${address.address}/$prefix';
  }
}

/// Slows down password guessing with doubling waits (max 1 hour) after
/// repeated failures, counted three ways:
///
/// * per address and username ([freeAttempts]) – someone mistyping,
/// * per address over all usernames ([addressAttempts]) – trying many
///   accounts ("password spraying"),
/// * per username over all addresses ([accountAttempts]) – guessing one
///   account from many machines.
///
/// The last count would let anyone who knows a username lock its owner
/// out. Addresses that signed in to an account successfully within
/// [trustFor] are therefore exempt from it for that account; the other
/// two limits still apply to them.
class LoginThrottle {
  LoginThrottle({
    this.freeAttempts = 5,
    this.addressAttempts = 20,
    this.accountAttempts = 20,
    this.trustFor = const Duration(days: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int freeAttempts;
  final int addressAttempts;
  final int accountAttempts;
  final Duration trustFor;
  final DateTime Function() _clock;
  final _failures = <String, _Failures>{};

  /// Last successful login per "address|username".
  final _trusted = <String, DateTime>{};

  static const _maxBlock = Duration(hours: 1);

  /// Failures are forgotten this long after the last one.
  static const _forgetAfter = Duration(hours: 1);

  /// Bound on remembered keys; blocked ones are never dropped.
  static const _maxEntries = 10000;

  /// Remaining block time, or null if a login may be attempted.
  Duration? blockedFor(String address, String username) {
    final now = _clock();
    Duration? longest;
    final trusted = _isTrusted(address, username, now);
    for (final key in _keys(address, username)) {
      if (trusted && key.startsWith('account|')) continue;
      final until = _failures[key]?.blockedUntil;
      if (until == null || !until.isAfter(now)) continue;
      final left = until.difference(now);
      if (longest == null || left > longest) longest = left;
    }
    return longest;
  }

  void failed(String address, String username) {
    final now = _clock();
    final keys = _keys(address, username);
    final limits = [freeAttempts, addressAttempts, accountAttempts];
    for (var i = 0; i < keys.length; i++) {
      final previous = _failures[keys[i]];
      final count =
          (previous == null ||
                  now.difference(previous.last) > _forgetAfter &&
                      !(previous.blockedUntil?.isAfter(now) ?? false)
              ? 0
              : previous.count) +
          1;
      DateTime? until;
      if (count >= limits[i]) {
        final seconds = min(
          30 * pow(2, min(count - limits[i], 12)).toInt(),
          _maxBlock.inSeconds,
        );
        until = now.add(Duration(seconds: seconds));
      }
      _failures[keys[i]] = _Failures(count, until, now);
    }
    if (_failures.length > _maxEntries) _prune(now);
  }

  /// A successful login forgives this address's mistakes with this
  /// account (not the counts over all accounts or addresses).
  void succeeded(String address, String username) {
    final key = _keys(address, username).first;
    _failures.remove(key);
    final now = _clock();
    _trusted[key] = now;
    if (_trusted.length > _maxEntries) {
      _trusted.removeWhere((_, at) => now.difference(at) > trustFor);
      // Still too many: the oldest go first.
      if (_trusted.length > _maxEntries) {
        final oldest = _trusted.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        for (final e in oldest.take(_trusted.length - _maxEntries)) {
          _trusted.remove(e.key);
        }
      }
    }
  }

  bool _isTrusted(String address, String username, DateTime now) {
    final at = _trusted[_keys(address, username).first];
    return at != null && now.difference(at) <= trustFor;
  }

  /// Drops forgotten entries, then the oldest unblocked ones – never an
  /// active block, so flooding with made-up names cannot lift one.
  void _prune(DateTime now) {
    _failures.removeWhere(
      (_, f) =>
          now.difference(f.last) > _forgetAfter &&
          !(f.blockedUntil?.isAfter(now) ?? false),
    );
    if (_failures.length <= _maxEntries) return;
    final unblocked =
        _failures.entries
            .where((e) => !(e.value.blockedUntil?.isAfter(now) ?? false))
            .toList()
          ..sort((a, b) => a.value.last.compareTo(b.value.last));
    for (final e in unblocked.take(_failures.length - _maxEntries)) {
      _failures.remove(e.key);
    }
  }

  static List<String> _keys(String address, String username) {
    final name = username.trim().toLowerCase();
    return ['$address|$name', 'address|$address', 'account|$name'];
  }
}

class _Failures {
  _Failures(this.count, this.blockedUntil, this.last);

  final int count;
  final DateTime? blockedUntil;
  final DateTime last;
}

/// One-time code for creating the first account through a proxy.
String newSetupCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O, 1/I
  final random = Random.secure();
  return List.generate(
    8,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}
