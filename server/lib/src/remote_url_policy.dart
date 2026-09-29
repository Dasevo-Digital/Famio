import 'dart:io';

import 'api_exception.dart';
import 'security.dart';

/// Validates destinations fetched by the server on a member's behalf.
///
/// Calendar URLs otherwise let an authenticated member probe services in the
/// server's home or container network. Private targets are an explicit
/// deployment opt-in for installations that really host a calendar locally.
class RemoteUrlPolicy {
  const RemoteUrlPolicy({this.allowPrivateNetwork = false});

  final bool allowPrivateNetwork;

  Future<void> check(Uri uri) async {
    if ((!(uri.isScheme('https') ||
            allowPrivateNetwork && uri.isScheme('http'))) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ApiException.badRequest(
        'unsafe_remote_url',
        'Externe Ziele brauchen eine HTTPS-Adresse ohne Zugangsdaten in der Adresse.',
      );
    }
    if (allowPrivateNetwork) return;
    final literal = InternetAddress.tryParse(uri.host);
    if (literal != null && ClientAddress.isPrivate(literal)) _blocked(uri);
    if (uri.host.toLowerCase() == 'localhost') _blocked(uri);
    try {
      final addresses = await InternetAddress.lookup(uri.host);
      if (addresses.any(ClientAddress.isPrivate)) _blocked(uri);
    } on SocketException {
      // The caller reports unreachable hosts without disclosing resolver data.
    }
  }

  Never _blocked(Uri uri) => throw ApiException.badRequest(
    'unsafe_remote_url',
    'Die Adresse ${uri.host} zeigt in ein privates Netzwerk. '
        'Lokale Ziele müssen vom Server ausdrücklich freigegeben werden.',
  );
}
