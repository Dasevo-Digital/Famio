/// What someone typed as a web address: "beispiel.de/konto" means
/// `https://beispiel.de/konto`. Null for nothing, for other kinds of links
/// ("mailto:", "tel:" – which a plain "https://" in front would turn into a
/// user name of an odd web address, HAU-101) and for addresses without a
/// host.
Uri? webLink(String text) {
  final typed = text.trim();
  if (typed.isEmpty) return null;
  final uri = Uri.tryParse(_hasScheme(typed) ? typed : 'https://$typed');
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

/// "mailto:…", "tel:…" or "https://…", but not "beispiel.de:8080" or
/// "localhost:3000", whose colon starts a port.
bool _hasScheme(String text) {
  final match = RegExp(
    r'^([a-z][a-z0-9+.-]*):(.?)',
    caseSensitive: false,
  ).firstMatch(text);
  if (match == null) return false;
  final name = match[1]!.toLowerCase();
  final port = RegExp(r'\d').hasMatch(match[2]!);
  return !port || (!name.contains('.') && name != 'localhost');
}
