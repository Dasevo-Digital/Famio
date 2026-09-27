import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

const _dav = 'DAV:';
const _caldav = 'urn:ietf:params:xml:ns:caldav';
const _cs = 'http://calendarserver.org/ns/';
const _ical = 'http://apple.com/ns/ical/';

/// A problem talking to the other calendar server, with a message for the
/// family.
class DavException implements Exception {
  DavException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// The other side changed the resource meanwhile (HTTP 412).
class DavConflict implements Exception {}

class DavResponse {
  DavResponse(this.status, this.headers, this.body, this.url);

  final int status;
  final Map<String, String> headers;
  final String body;

  /// Where the answer came from, after redirects.
  final Uri url;
}

/// One `<response>` of a multistatus answer.
class DavEntry {
  DavEntry(this.href, this.status, this.props);

  final String href;

  /// Status of the whole response (e.g. 404 for a missing resource), or of
  /// the found properties.
  final int status;

  /// Properties returned with 200, by `(namespace, name)`.
  final Map<(String, String), XmlElement> props;

  XmlElement? prop(String ns, String name) => props[(ns, name)];

  String? text(String ns, String name) => prop(ns, name)?.innerText.trim();

  /// The first `<href>` inside a property.
  String? href_(String ns, String name) => prop(
    ns,
    name,
  )?.findAllElements('href', namespaceUri: _dav).firstOrNull?.innerText.trim();

  bool isA(String ns, String type) =>
      prop(_dav, 'resourcetype')?.childElements.any(
        (e) => e.name.namespaceUri == ns && e.name.local == type,
      ) ??
      false;
}

/// Minimal WebDAV/CalDAV client (RFC 4918, 4791) for the requests Famio
/// needs: discovery, listing, fetching, writing and deleting events.
class DavClient {
  DavClient(
    this._http, {
    this.username = '',
    this.password = '',
    this.bearer,
    this.timeout = const Duration(seconds: 30),
  });

  final http.Client _http;
  final String username;
  final String password;

  /// OAuth instead of a password (Google): returns an access token, a new
  /// one when [force]d after the server refused the old one.
  final Future<String> Function({bool force})? bearer;
  final Duration timeout;

  static const _maxBytes = 20 * 1024 * 1024;

  Future<DavResponse> send(
    String method,
    Uri url, {
    String? body,
    String? depth,
    Map<String, String> headers = const {},
  }) async {
    var target = url;
    var renewed = false;
    var forceToken = false;
    for (var hop = 0; hop < 6; hop++) {
      final token = bearer == null ? null : await bearer!(force: forceToken);
      forceToken = false;
      final request = http.Request(method, target)
        ..followRedirects = false
        ..headers['authorization'] = bearer == null
            ? 'Basic ${base64.encode(utf8.encode('$username:$password'))}'
            : 'Bearer $token'
        ..headers['user-agent'] = 'Famio CalDAV'
        ..headers.addAll(headers);
      if (depth != null) request.headers['depth'] = depth;
      if (body != null) {
        request.headers['content-type'] ??= 'application/xml; charset=utf-8';
        request.bodyBytes = utf8.encode(body);
      }
      final http.StreamedResponse response;
      try {
        response = await _http.send(request).timeout(timeout);
      } on TimeoutException {
        throw DavException('Zeitüberschreitung bei ${target.host}');
      } on SocketException catch (e) {
        throw DavException('${target.host} nicht erreichbar (${e.message})');
      } on HandshakeException {
        throw DavException(
          'Verschlüsselung zu ${target.host} fehlgeschlagen (Zertifikat?)',
        );
      } on http.ClientException catch (e) {
        throw DavException('Verbindung zu ${target.host}: ${e.message}');
      }
      final location = response.headers['location'];
      if (response.statusCode >= 300 &&
          response.statusCode < 400 &&
          location != null) {
        await response.stream.drain<void>();
        target = target.resolve(location);
        continue;
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBytes) {
          throw DavException('Antwort von ${target.host} ist zu groß');
        }
      }
      if (response.statusCode == 401 && bearer != null && !renewed) {
        renewed = true; // The access token expired early: once more.
        forceToken = true;
        continue;
      }
      if (response.statusCode == 401) {
        throw DavException(
          'Anmeldung bei ${target.host} fehlgeschlagen – Benutzername oder '
          '(App-)Passwort prüfen',
          status: 401,
        );
      }
      return DavResponse(
        response.statusCode,
        response.headers,
        utf8.decode(bytes, allowMalformed: true),
        target,
      );
    }
    throw DavException('Zu viele Weiterleitungen');
  }

  Future<(List<DavEntry>, Uri)> propfind(
    Uri url,
    String props, {
    String depth = '0',
  }) async {
    final response = await send(
      'PROPFIND',
      url,
      depth: depth,
      body:
          '<?xml version="1.0" encoding="utf-8"?>'
          '<d:propfind xmlns:d="DAV:" xmlns:c="$_caldav" xmlns:cs="$_cs" '
          'xmlns:ical="$_ical"><d:prop>$props</d:prop></d:propfind>',
    );
    if (response.status != 207) {
      throw DavException(
        'Unerwartete Antwort von ${url.host} (HTTP ${response.status})',
        status: response.status,
      );
    }
    return (parseMultistatus(response.body), response.url);
  }

  /// Finds the calendars reachable from [start]: a server address (with
  /// `/.well-known/caldav` discovery), a principal or a calendar URL.
  Future<List<CalDavCalendarInfo>> discover(Uri start) async {
    const props =
        '<d:resourcetype/><d:displayname/><d:current-user-principal/>'
        '<c:calendar-home-set/><c:supported-calendar-component-set/>'
        '<ical:calendar-color/><d:current-user-privilege-set/>';
    List<DavEntry> entries;
    Uri base;
    try {
      (entries, base) = await propfind(start, props);
    } on DavException catch (e) {
      if (e.status == null || e.status == 401) rethrow;
      (entries, base) = await propfind(
        start.resolve('/.well-known/caldav'),
        props,
      );
    }
    final self = entries.firstOrNull;
    if (self == null) throw DavException('Keine Kalender gefunden');
    if (self.isA(_caldav, 'calendar')) {
      return [?_calendar(self, base)];
    }

    var home = self.href_(_caldav, 'calendar-home-set');
    if (home == null) {
      var principal = self.href_(_dav, 'current-user-principal');
      if (principal == null && start.path.length <= 1) {
        // Some servers answer the site root without it; try well-known.
        final (e2, b2) = await propfind(
          start.resolve('/.well-known/caldav'),
          props,
        );
        base = b2;
        principal = e2.firstOrNull?.href_(_dav, 'current-user-principal');
      }
      if (principal == null) {
        throw DavException(
          'Unter dieser Adresse wurde kein CalDAV-Konto gefunden',
        );
      }
      final principalUrl = base.resolve(principal);
      final (p, pBase) = await propfind(principalUrl, props);
      base = pBase;
      home = p.firstOrNull?.href_(_caldav, 'calendar-home-set');
      if (home == null) throw DavException('Keine Kalender gefunden');
    }
    final homeUrl = base.resolve(home);
    final (list, listBase) = await propfind(homeUrl, props, depth: '1');
    return [
      for (final e in list)
        if (e.isA(_caldav, 'calendar')) ?_calendar(e, listBase),
    ];
  }

  CalDavCalendarInfo? _calendar(DavEntry e, Uri base) {
    final components = e
        .prop(_caldav, 'supported-calendar-component-set')
        ?.findElements('comp', namespaceUri: _caldav)
        .map((c) => c.getAttribute('name')?.toUpperCase())
        .toSet();
    // Reminder or task lists (VTODO only) are of no use here.
    if (components != null &&
        components.isNotEmpty &&
        !components.contains('VEVENT')) {
      return null;
    }
    final privileges = e
        .prop(_dav, 'current-user-privilege-set')
        ?.findAllElements('privilege', namespaceUri: _dav)
        .expand((p) => p.childElements.map((c) => c.name.local))
        .toSet();
    final readOnly =
        privileges != null &&
        privileges.isNotEmpty &&
        !privileges.any(
          (p) => p == 'write' || p == 'write-content' || p == 'all',
        );
    final name = e.text(_dav, 'displayname');
    return CalDavCalendarInfo(
      url: base.resolve(e.href).toString(),
      name: name == null || name.isEmpty ? 'Kalender' : name,
      color: _color(e.text(_ical, 'calendar-color')),
      readOnly: readOnly,
    );
  }

  static int? _color(String? hex) {
    if (hex == null || !hex.startsWith('#')) return null;
    final v = hex.substring(1);
    if (v.length != 6 && v.length != 8) return null;
    final rgb = int.tryParse(v.substring(0, 6), radix: 16);
    return rgb == null ? null : 0xFF000000 | rgb;
  }

  /// Change tag of a calendar (CTag, else sync token), null if unknown.
  Future<String?> changeTag(Uri calendar) async {
    final (entries, _) = await propfind(
      calendar,
      '<cs:getctag/><d:sync-token/>',
    );
    final e = entries.firstOrNull;
    return e?.text(_cs, 'getctag') ?? e?.text(_dav, 'sync-token');
  }

  /// ETags of all resources in [calendar], by path.
  Future<Map<String, String>> etags(Uri calendar) async {
    final (entries, base) = await propfind(
      calendar,
      '<d:resourcetype/><d:getetag/><d:getcontenttype/>',
      depth: '1',
    );
    final own = base.resolve(calendar.path).path;
    return {
      for (final e in entries)
        if (base.resolve(e.href).path != own &&
            !e.isA(_dav, 'collection') &&
            e.status == 200 &&
            e.text(_dav, 'getetag') != null)
          base.resolve(e.href).path: e.text(_dav, 'getetag')!,
    };
  }

  /// Calendar data and ETag of [paths], fetched in batches.
  Future<Map<String, (String etag, String data)>> fetch(
    Uri calendar,
    List<String> paths,
  ) async {
    final result = <String, (String, String)>{};
    for (var i = 0; i < paths.length; i += 50) {
      final batch = paths.sublist(i, (i + 50).clamp(0, paths.length));
      final response = await send(
        'REPORT',
        calendar,
        depth: '1',
        body:
            '<?xml version="1.0" encoding="utf-8"?>'
            '<c:calendar-multiget xmlns:d="DAV:" xmlns:c="$_caldav">'
            '<d:prop><d:getetag/><c:calendar-data/></d:prop>'
            '${batch.map((p) => '<d:href>${_esc(p)}</d:href>').join()}'
            '</c:calendar-multiget>',
      );
      if (response.status == 207) {
        for (final e in parseMultistatus(response.body)) {
          final etag = e.text(_dav, 'getetag');
          final data = e.prop(_caldav, 'calendar-data')?.innerText;
          if (e.status == 200 && etag != null && data != null) {
            result[response.url.resolve(e.href).path] = (etag, data);
          }
        }
      } else {
        // No multiget: fetch one by one.
        for (final path in batch) {
          final r = await send('GET', calendar.resolve(path));
          final etag = r.headers['etag'];
          if (r.status == 200 && etag != null) result[path] = (etag, r.body);
        }
      }
    }
    return result;
  }

  /// Writes a resource; returns its new ETag if the server tells it.
  /// Throws [DavConflict] if [ifMatch] no longer matches or it exists
  /// although [create] was asked for.
  Future<String?> put(
    Uri resource,
    String ics, {
    String? ifMatch,
    bool create = false,
  }) async {
    final response = await send(
      'PUT',
      resource,
      body: ics,
      headers: {
        'content-type': 'text/calendar; charset=utf-8',
        'if-match': ?ifMatch,
        if (create) 'if-none-match': '*',
      },
    );
    if (response.status == 412) throw DavConflict();
    if (response.status < 200 || response.status >= 300) {
      throw DavException(
        'Termin konnte nicht gespeichert werden (HTTP ${response.status})',
        status: response.status,
      );
    }
    return response.headers['etag'];
  }

  Future<void> delete(Uri resource, {String? ifMatch}) async {
    final response = await send(
      'DELETE',
      resource,
      headers: {'if-match': ?ifMatch},
    );
    if (response.status == 412) throw DavConflict();
    if (response.status == 404 || response.status == 410) return;
    if (response.status < 200 || response.status >= 300) {
      throw DavException(
        'Termin konnte nicht gelöscht werden (HTTP ${response.status})',
        status: response.status,
      );
    }
  }

  /// Current ETag of one resource, null if it does not exist.
  Future<String?> etagOf(Uri resource) async {
    try {
      final (entries, _) = await propfind(resource, '<d:getetag/>');
      return entries.firstOrNull?.text(_dav, 'getetag');
    } on DavException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

/// Parses a `<multistatus>` body.
List<DavEntry> parseMultistatus(String body) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(body);
  } on XmlException {
    throw DavException('Ungültige Antwort des Kalenderservers');
  }
  int statusOf(XmlElement? e) {
    final text = e?.innerText.trim() ?? '';
    return int.tryParse(text.split(' ').elementAtOrNull(1) ?? '') ?? 200;
  }

  return [
    for (final r in doc.findAllElements('response', namespaceUri: _dav))
      () {
        final href =
            r
                .findElements('href', namespaceUri: _dav)
                .firstOrNull
                ?.innerText
                .trim() ??
            '';
        final props = <(String, String), XmlElement>{};
        var status = statusOf(
          r.findElements('status', namespaceUri: _dav).firstOrNull,
        );
        for (final ps in r.findElements('propstat', namespaceUri: _dav)) {
          final s = statusOf(
            ps.findElements('status', namespaceUri: _dav).firstOrNull,
          );
          if (s != 200) continue;
          for (final p in ps.findAllElements('prop', namespaceUri: _dav)) {
            for (final c in p.childElements) {
              props[(c.name.namespaceUri ?? '', c.name.local)] = c;
            }
          }
        }
        if (props.isNotEmpty) status = 200;
        return DavEntry(href, status, props);
      }(),
  ];
}
