import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Time-based one-time passwords (RFC 6238) as shown by authenticator apps:
/// HMAC-SHA1, 6 digits, 30 second steps.
class Totp {
  static const digits = 6;
  static const period = 30;

  static final _random = Random.secure();

  /// A new shared secret (160 bits), base32 without padding.
  static String newSecret() =>
      base32Encode(List<int>.generate(20, (_) => _random.nextInt(256)));

  /// The time step of [time].
  static int stepOf(DateTime time) =>
      time.millisecondsSinceEpoch ~/ 1000 ~/ period;

  /// The code for [secret] at time step [step].
  static String code(String secret, int step) {
    final counter = ByteData(8)..setUint64(0, step);
    final hash = Hmac(
      sha1,
      base32Decode(secret),
    ).convert(counter.buffer.asUint8List()).bytes;
    final offset = hash.last & 0x0f;
    final value =
        ((hash[offset] & 0x7f) << 24) |
        (hash[offset + 1] << 16) |
        (hash[offset + 2] << 8) |
        hash[offset + 3];
    return (value % pow(10, digits)).toString().padLeft(digits, '0');
  }

  /// The time step [input] belongs to, allowing one step of clock drift
  /// either way, or null. Steps up to [usedStep] are refused, so a code
  /// seen by somebody else cannot be used again.
  static int? verify(
    String secret,
    String input, {
    DateTime? now,
    int? usedStep,
  }) {
    final given = input.replaceAll(RegExp(r'\s'), '');
    if (!RegExp('^[0-9]{$digits}\$').hasMatch(given)) return null;
    final current = stepOf(now ?? DateTime.now());
    for (final step in [current, current - 1, current + 1]) {
      if (usedStep != null && step <= usedStep) continue;
      if (_equals(code(secret, step), given)) return step;
    }
    return null;
  }

  /// The `otpauth://` link authenticator apps read from a QR code.
  static Uri uri(String secret, {required String account, String? issuer}) {
    final label = issuer == null ? account : '$issuer:$account';
    return Uri(
      scheme: 'otpauth',
      host: 'totp',
      path: '/$label',
      queryParameters: {
        'secret': secret,
        'issuer': ?issuer,
        'algorithm': 'SHA1',
        'digits': '$digits',
        'period': '$period',
      },
    );
  }

  static bool _equals(String a, String b) {
    var diff = a.length ^ b.length;
    for (var i = 0; i < min(a.length, b.length); i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  static String base32Encode(List<int> bytes) {
    final out = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in bytes) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        out.write(_alphabet[(buffer >> (bits - 5)) & 31]);
        bits -= 5;
      }
    }
    if (bits > 0) out.write(_alphabet[(buffer << (5 - bits)) & 31]);
    return out.toString();
  }

  static Uint8List base32Decode(String text) {
    final clean = text.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '');
    final out = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final char in clean.split('')) {
      final value = _alphabet.indexOf(char);
      if (value < 0) throw FormatException('Kein Base32: $char');
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        out.add((buffer >> (bits - 8)) & 0xff);
        bits -= 8;
      }
    }
    return Uint8List.fromList(out);
  }
}
