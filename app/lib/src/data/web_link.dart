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

/// "mailto:…", "tel:…" or "https://…", but not "beispiel.de:8080",
/// "localhost:3000" or "nas:5000/rezept", whose colon starts a port. Only
/// link kinds that take numbers ("tel:110") keep a number after the colon.
bool _hasScheme(String text) {
  final match = RegExp(
    r'^([a-z][a-z0-9+.-]*):(.*)$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(text);
  if (match == null) return false;
  final name = match[1]!.toLowerCase();
  final port = RegExp(r'^\d{1,5}(?:[/?#]|$)').hasMatch(match[2]!);
  return !port || _numbered.contains(name);
}

const _numbered = {'tel', 'sms', 'fax', 'callto', 'facetime', 'geo'};
