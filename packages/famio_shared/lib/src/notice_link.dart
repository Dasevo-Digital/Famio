/// The link a notification carries that leaves through a service Famio does
/// not run (ntfy, #578): `famio://open?notice=<key>`. The key is random and
/// names one stored notification of one member; only the app of that member
/// learns from the server what it opens (a `NoticeTarget`). Unlike a
/// target link (`famio://open?target=…`) it says nothing about the entry:
/// not which chat, appointment or task, and not who wrote to whom.
abstract final class NoticeLink {
  /// The query parameter of the key.
  static const parameter = 'notice';

  /// How the phones hand a key over to Dart, next to plain targets.
  static const prefix = 'notice:';

  /// The link for [key].
  static String of(String key) => Uri(
    scheme: 'famio',
    host: 'open',
    queryParameters: {parameter: key},
  ).toString();

  /// The key of a [of] link, null for any other address.
  static String? keyOf(Uri uri) => uri.scheme == 'famio' && uri.host == 'open'
      ? _valid(uri.queryParameters[parameter])
      : null;

  /// The key in what a phone handed over (`notice:<key>`), else null.
  static String? keyIn(String? handedOver) =>
      handedOver != null && handedOver.startsWith(prefix)
      ? _valid(handedOver.substring(prefix.length))
      : null;

  static String? _valid(String? key) =>
      key != null && RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(key)
      ? key
      : null;
}
