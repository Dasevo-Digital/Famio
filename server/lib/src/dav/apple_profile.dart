import 'dart:convert';
import 'dart:math';

/// A configuration profile (`.mobileconfig`) that adds a CalDAV account to
/// Apple Calendar on a Mac, iPhone or iPad. With [rootCertificate] (DER) the
/// device also trusts the server's own certificate authority: Apple Calendar
/// only sends passwords over HTTPS.
String appleCalendarProfile({
  required String host,
  required int port,
  required String principalUrl,
  required String username,
  required String password,
  List<int>? rootCertificate,
}) {
  final random = Random.secure();
  String uuid() {
    final b = List<int>.generate(16, (_) => random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
            '${h.substring(16, 20)}-${h.substring(20)}'
        .toUpperCase();
  }

  String esc(String v) => const HtmlEscape(HtmlEscapeMode.element).convert(v);
  final id = 'de.status403.famio.caldav.${esc(host)}';
  final certificate = rootCertificate == null
      ? ''
      : '''
		<dict>
			<key>PayloadCertificateFileName</key>
			<string>Famio-Heimserver.cer</string>
			<key>PayloadContent</key>
			<data>${base64.encode(rootCertificate)}</data>
			<key>PayloadDescription</key>
			<string>Vertraut dem eigenen Zertifikat des Famio-Servers.</string>
			<key>PayloadDisplayName</key>
			<string>Famio Heimserver</string>
			<key>PayloadIdentifier</key>
			<string>$id.root</string>
			<key>PayloadType</key>
			<string>com.apple.security.root</string>
			<key>PayloadUUID</key>
			<string>${uuid()}</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
		</dict>
''';
  return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
$certificate		<dict>
			<key>CalDAVAccountDescription</key>
			<string>Famio</string>
			<key>CalDAVHostName</key>
			<string>${esc(host)}</string>
			<key>CalDAVPassword</key>
			<string>${esc(password)}</string>
			<key>CalDAVPort</key>
			<integer>$port</integer>
			<key>CalDAVPrincipalURL</key>
			<string>${esc(principalUrl)}</string>
			<key>CalDAVUseSSL</key>
			<true/>
			<key>CalDAVUsername</key>
			<string>${esc(username)}</string>
			<key>PayloadDisplayName</key>
			<string>Famio-Kalender</string>
			<key>PayloadIdentifier</key>
			<string>$id.account</string>
			<key>PayloadType</key>
			<string>com.apple.caldav.account</string>
			<key>PayloadUUID</key>
			<string>${uuid()}</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
		</dict>
	</array>
	<key>PayloadDescription</key>
	<string>Verbindet Apple Kalender mit Famio. Enthält ein eigenes App-Passwort, das sich in Famio jederzeit widerrufen lässt.</string>
	<key>PayloadDisplayName</key>
	<string>Famio-Kalender</string>
	<key>PayloadIdentifier</key>
	<string>$id</string>
	<key>PayloadRemovalDisallowed</key>
	<false/>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>${uuid()}</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
</dict>
</plist>
''';
}
