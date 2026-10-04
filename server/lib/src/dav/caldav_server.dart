import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:xml/xml.dart';

import '../accounts.dart';
import '../calendar/event_ics.dart';
import '../calendar/ics.dart';
import '../calendar/todo_ics.dart';
import '../family/repeating_tasks.dart';
import '../record_store.dart';
import '../security.dart';

const _dav = 'DAV:';
const _caldav = 'urn:ietf:params:xml:ns:caldav';
const _cs = 'http://calendarserver.org/ns/';
const _ical = 'http://apple.com/ns/ical/';

/// Prefixes used in responses; other namespaces get their own on the spot.
const _prefixes = {_dav: 'd', _caldav: 'c', _cs: 'cs', _ical: 'ical'};

/// Famio's family calendar, tasks and shopping lists as a CalDAV server
/// (RFC 4791), so Apple Calendar and Reminders, Thunderbird or DAVx5
/// (Android) can show and edit them directly.
///
/// Layout (per member, showing what that member may see):
///
///     /dav/principals/<username>/
///     /dav/calendars/<username>/famio/<event id>.ics        events (VEVENT)
///     /dav/calendars/<username>/aufgaben/<task id>.ics      tasks (VTODO)
///     /dav/calendars/<username>/einkauf-<list id>/<item id>.ics
///                                                           shopping (VTODO)
///
/// Calendar apps log in with the username and an app password
/// ([Accounts.createAppPassword]), never with the Famio password.
class CalDavServer {
  CalDavServer({
    required this.accounts,
    required this.records,
    required this.location,
    required this.throttle,
    required this.clientAddress,
    required this.onChanged,
    this.onRecordsChanged,
  });

  final Accounts accounts;
  final RecordStore records;
  final tz.Location Function() location;
  final LoginThrottle throttle;
  final ClientAddress clientAddress;

  /// Called after events were written, e.g. to notify connected apps.
  final void Function() onChanged;

  /// Called after tasks or shopping items were written.
  final void Function()? onRecordsChanged;

  static const calendarSlug = 'famio';
  static const tasksSlug = 'aufgaben';
  static const shoppingPrefix = 'einkauf-';
  static const _maxBody = 1024 * 1024;
  static const _syncTokenPrefix = 'http://famio.app/ns/sync/';

  /// Whether [request] is for this server (well-known discovery included;
  /// some apps probe the site root with PROPFIND).
  static bool handles(Request request) {
    final path = request.url.path;
    return path == 'dav' ||
        path.startsWith('dav/') ||
        path.startsWith('.well-known/caldav') ||
        (path.isEmpty && request.method != 'GET' && request.method != 'HEAD');
  }

  Future<Response> handle(Request request) async {
    final path = request.url.path;
    if (path.startsWith('.well-known/caldav')) {
      return Response(301, headers: {'location': '/dav/'});
    }
    if (request.method == 'OPTIONS') return _options();

    final login = _login(request);
    if (login == null) {
      return Response(
        401,
        body: 'Anmeldung mit Benutzername und App-Passwort nötig',
        headers: {
          'www-authenticate': 'Basic realm="Famio", charset="UTF-8"',
          'content-type': 'text/plain; charset=utf-8',
        },
      );
    }
    final (member, password) = login;
    final context = _Context(member, password);

    final segments = [
      for (final s in request.url.pathSegments)
        if (s.isNotEmpty) s,
    ];
    // The site root answers like /dav/ (principal discovery).
    final parts = segments.isEmpty ? <String>[] : segments.sublist(1);
    final target = _Target.parse(parts);
    if (target == null) return _status(404);
    if (target.user != null &&
        target.user!.toLowerCase() != member.username.toLowerCase()) {
      return _status(403);
    }

    try {
      return switch (request.method) {
        'PROPFIND' => await _propfind(request, context, target),
        'REPORT' => await _report(request, context, target),
        'GET' || 'HEAD' => _get(request, context, target),
        'PUT' => await _put(request, context, target),
        'DELETE' => _delete(request, context, target),
        'PROPPATCH' => await _proppatch(request, target),
        _ => _status(405),
      };
    } on XmlException {
      return _status(400, 'Ungültiges XML');
    } on _DavError catch (e) {
      return e.response;
    }
  }

  (FamilyMember, AppPassword)? _login(Request request) {
    final header = request.headers['authorization'];
    if (header == null || !header.startsWith('Basic ')) return null;
    final String decoded;
    try {
      decoded = utf8.decode(base64.decode(header.substring(6).trim()));
    } on FormatException {
      return null;
    }
    final colon = decoded.indexOf(':');
    if (colon <= 0) return null;
    final username = decoded.substring(0, colon);
    final address = clientAddress.of(request);
    final key = '#dav:${username.toLowerCase()}';
    if (throttle.blockedFor(address, key) != null) return null;
    final login = accounts.appPasswordLogin(
      username,
      decoded.substring(colon + 1),
    );
    if (login == null) {
      throttle.failed(address, key);
      return null;
    }
    throttle.succeeded(address, key);
    return login;
  }

  Response _options() => Response.ok(
    null,
    headers: {
      'dav': '1, 3, calendar-access',
      'allow': 'OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, REPORT',
    },
  );

  // --- PROPFIND -------------------------------------------------------------

  Future<Response> _propfind(
    Request request,
    _Context context,
    _Target target,
  ) async {
    final wanted = _requestedProps(await _xmlBody(request));
    final depth = request.headers['depth'] ?? '1';
    final responses = StringBuffer();
    final user = context.member.username;

    switch (target.kind) {
      case _Kind.root:
        responses.write(_response('/dav/', _rootProps(context), wanted));
      case _Kind.principals:
        responses.write(
          _response('/dav/principals/', _rootProps(context), wanted),
        );
      case _Kind.principal:
        responses.write(
          _response(_principalHref(user), _principalProps(context), wanted),
        );
      case _Kind.home:
        responses.write(
          _response(_homeHref(user), _homeProps(context), wanted),
        );
        if (depth != '0') {
          for (final c in _collections(context)) {
            responses.write(
              _response(
                _collectionHref(user, c),
                _calendarProps(context, c),
                wanted,
              ),
            );
          }
        }
      case _Kind.calendar:
        final c = _collection(context, target);
        if (c == null) return _status(404);
        responses.write(
          _response(
            _collectionHref(user, c),
            _calendarProps(context, c),
            wanted,
          ),
        );
        if (depth != '0') {
          for (final r in _exposed(context, c)) {
            responses.write(
              _response(
                _resourceHref(user, c, r.id),
                _resourceProps(r, c, withData: false),
                wanted,
              ),
            );
          }
        }
      case _Kind.event:
        final c = _collection(context, target);
        final r = c == null
            ? null
            : _exposedRecord(context, c, target.eventId!);
        if (c == null || r == null) return _status(404);
        responses.write(
          _response(
            _resourceHref(user, c, r.id),
            _resourceProps(r, c, withData: false),
            wanted,
          ),
        );
    }
    return _multistatus(responses.toString());
  }

  /// Requested properties as `{namespace}name`; null for all (allprop or
  /// an empty body).
  static List<(String, String)>? _requestedProps(XmlDocument? body) {
    final prop = body?.rootElement
        .findElements('prop', namespaceUri: _dav)
        .firstOrNull;
    if (prop == null) return null;
    return [
      for (final e in prop.childElements)
        (e.name.namespaceUri ?? '', e.name.local),
    ];
  }

  Map<(String, String), String> _rootProps(_Context c) => {
    (_dav, 'resourcetype'): '<d:collection/>',
    (_dav, 'displayname'): 'Famio',
    (_dav, 'current-user-principal'): _hrefXml(
      _principalHref(c.member.username),
    ),
    (_dav, 'principal-URL'): _hrefXml(_principalHref(c.member.username)),
  };

  Map<(String, String), String> _principalProps(_Context c) {
    final user = c.member.username;
    return {
      (_dav, 'resourcetype'): '<d:principal/>',
      (_dav, 'displayname'): _esc(c.member.displayName),
      (_dav, 'current-user-principal'): _hrefXml(_principalHref(user)),
      (_dav, 'principal-URL'): _hrefXml(_principalHref(user)),
      (_caldav, 'calendar-home-set'): _hrefXml(_homeHref(user)),
      (_caldav, 'calendar-user-type'): 'INDIVIDUAL',
    };
  }

  Map<(String, String), String> _homeProps(_Context c) {
    final user = c.member.username;
    return {
      (_dav, 'resourcetype'): '<d:collection/>',
      (_dav, 'displayname'): _esc(c.member.displayName),
      (_dav, 'current-user-principal'): _hrefXml(_principalHref(user)),
      (_dav, 'owner'): _hrefXml(_principalHref(user)),
      (_dav, 'current-user-privilege-set'): _privileges(write: false),
    };
  }

  Map<(String, String), String> _calendarProps(
    _Context c,
    _Collection collection,
  ) {
    final user = c.member.username;
    final rev = _collectionRev(c, collection);
    final (name, description, color) = switch (collection.kind) {
      _Content.events => (
        'Famio',
        'Termine der Familie aus Famio',
        '#7B5BE0FF',
      ),
      _Content.tasks => (
        'Famio-Aufgaben',
        'Aufgaben der Familie aus Famio',
        '#2A9D6EFF',
      ),
      _Content.shopping => (
        _shoppingListName(collection.listId!) ?? 'Einkauf',
        'Einkaufsliste aus Famio',
        '#E8703AFF',
      ),
    };
    final component = collection.todos ? 'VTODO' : 'VEVENT';
    return {
      (_dav, 'resourcetype'): '<d:collection/><c:calendar/>',
      (_dav, 'displayname'): _esc(name),
      (_caldav, 'calendar-description'): _esc(description),
      (_caldav, 'supported-calendar-component-set'):
          '<c:comp name="$component"/>',
      (_caldav, 'calendar-timezone'): _esc(_vtimezone()),
      (_cs, 'getctag'): '"$rev"',
      (_dav, 'sync-token'): '$_syncTokenPrefix$rev',
      (_ical, 'calendar-color'): color,
      (_dav, 'current-user-principal'): _hrefXml(_principalHref(user)),
      (_dav, 'owner'): _hrefXml(_principalHref(user)),
      (_dav, 'current-user-privilege-set'): _privileges(write: true),
      (_dav, 'supported-report-set'): [
        for (final r in [
          'c:calendar-multiget',
          'c:calendar-query',
          'd:sync-collection',
        ])
          '<d:supported-report><d:report><$r/></d:report></d:supported-report>',
      ].join(),
    };
  }

  String _vtimezone() {
    final zone = location();
    final w = IcsWriter()
      ..begin('VCALENDAR')
      ..line('VERSION', '2.0')
      ..line('PRODID', '-//Famio//Famio Server//DE');
    writeVTimezone(w, zone, DateTime.now().year);
    w.end('VCALENDAR');
    return w.toString();
  }

  Map<(String, String), String> _resourceProps(
    SyncRecord r,
    _Collection collection, {
    required bool withData,
  }) => {
    (_dav, 'resourcetype'): '',
    (_dav, 'getetag'): _esc(_etag(r)),
    (_dav, 'getcontenttype'):
        'text/calendar; charset=utf-8; '
        'component=${collection.todos ? 'vtodo' : 'vevent'}',
    (_dav, 'getlastmodified'): _httpDate(
      DateTime.fromMillisecondsSinceEpoch(r.updatedAt, isUtc: true),
    ),
    if (withData) (_caldav, 'calendar-data'): _esc(_ics(r, collection)),
  };

  static String _privileges({required bool write}) => [
    'read',
    'read-current-user-privilege-set',
    if (write) ...[
      'write',
      'write-content',
      'write-properties',
      'bind',
      'unbind',
    ],
  ].map((p) => '<d:privilege><d:$p/></d:privilege>').join();

  // --- REPORT ---------------------------------------------------------------

  Future<Response> _report(
    Request request,
    _Context context,
    _Target target,
  ) async {
    if (target.kind != _Kind.calendar && target.kind != _Kind.event) {
      return _status(403);
    }
    final collection = _collection(context, target);
    if (collection == null) return _status(404);
    final body = await _xmlBody(request);
    if (body == null) return _status(400, 'Leere Anfrage');
    final root = body.rootElement;
    final wanted = _requestedProps(body);
    final user = context.member.username;
    final responses = StringBuffer();

    Map<(String, String), String> props(SyncRecord r) => _resourceProps(
      r,
      collection,
      withData: wanted == null || wanted.contains((_caldav, 'calendar-data')),
    );

    switch ((root.name.namespaceUri, root.name.local)) {
      case (_caldav, 'calendar-multiget'):
        for (final href in root.findAllElements('href', namespaceUri: _dav)) {
          final id = _resourceIdFromHref(
            href.innerText.trim(),
            user,
            collection,
          );
          final r = id == null ? null : _exposedRecord(context, collection, id);
          if (r == null) {
            responses.write(_statusResponse(href.innerText.trim(), 404));
          } else {
            responses.write(
              _response(
                _resourceHref(user, collection, r.id),
                props(r),
                wanted,
              ),
            );
          }
        }
      case (_caldav, 'calendar-query'):
        final filter = _QueryFilter.parse(root);
        if (filter.component == 'VEVENT' && !collection.todos) {
          for (final r in _exposed(context, collection)) {
            if (!filter.matches(CalendarEvent.fromRecord(r))) continue;
            responses.write(
              _response(
                _resourceHref(user, collection, r.id),
                props(r),
                wanted,
              ),
            );
          }
        } else if (filter.component == 'VTODO' && collection.todos) {
          // Apps filter completed to-dos themselves; all of them is a
          // valid superset of what they asked for.
          for (final r in _exposed(context, collection)) {
            responses.write(
              _response(
                _resourceHref(user, collection, r.id),
                props(r),
                wanted,
              ),
            );
          }
        }
      case (_dav, 'sync-collection'):
        return _syncCollection(root, context, collection, wanted);
      default:
        return _davError(403, '<d:supported-report/>');
    }
    return _multistatus(responses.toString());
  }

  /// RFC 6578: what changed since the client's sync token.
  Response _syncCollection(
    XmlElement root,
    _Context context,
    _Collection collection,
    List<(String, String)>? wanted,
  ) {
    final user = context.member.username;
    final token =
        root
            .findElements('sync-token', namespaceUri: _dav)
            .firstOrNull
            ?.innerText
            .trim() ??
        '';
    final current = _collectionRev(context, collection);
    var since = 0;
    if (token.isNotEmpty) {
      final parsed = token.startsWith(_syncTokenPrefix)
          ? int.tryParse(token.substring(_syncTokenPrefix.length))
          : null;
      if (parsed == null || parsed > current) {
        return _davError(403, '<d:valid-sync-token/>');
      }
      since = parsed;
    }
    String href(String id) => _resourceHref(user, collection, id);
    final responses = StringBuffer();
    if (since == 0) {
      for (final r in _exposed(context, collection)) {
        responses.write(
          _response(
            href(r.id),
            _resourceProps(r, collection, withData: false),
            wanted,
          ),
        );
      }
    } else {
      final (changed, revoked) = records.changesSince(
        collection.records,
        since,
        context.member.id,
      );
      final reported = <String>{};
      for (final r in changed) {
        if (!reported.add(r.id)) continue;
        if (_isExposed(context, collection, r)) {
          responses.write(
            _response(
              href(r.id),
              _resourceProps(r, collection, withData: false),
              wanted,
            ),
          );
        } else if (r.deleted || RecordStore.canSee(r, context.member.id)) {
          // Deleted, or (shopping) on another list: gone from here. Items of
          // other lists the app never had are simply ignored by it.
          if (!collection.todos ||
              r.deleted ||
              collection.kind != _Content.shopping ||
              _onList(r, collection)) {
            responses.write(_statusResponse(href(r.id), 404));
          }
        }
      }
      for (final id in revoked.where(reported.add)) {
        responses.write(_statusResponse(href(id), 404));
      }
    }
    responses.write('<d:sync-token>$_syncTokenPrefix$current</d:sync-token>');
    return _multistatus(responses.toString());
  }

  // --- GET / PUT / DELETE ---------------------------------------------------

  Response _get(Request request, _Context context, _Target target) {
    if (target.kind != _Kind.event) {
      return target.kind == _Kind.calendar ? _status(403) : _status(404);
    }
    final collection = _collection(context, target);
    final r = collection == null
        ? null
        : _exposedRecord(context, collection, target.eventId!);
    if (collection == null || r == null) return _status(404);
    final text = _ics(r, collection);
    return Response.ok(
      request.method == 'HEAD' ? null : text,
      headers: {
        'content-type': 'text/calendar; charset=utf-8',
        'etag': _etag(r),
        if (request.method == 'HEAD')
          'content-length': '${utf8.encode(text).length}',
      },
    );
  }

  Future<Response> _put(
    Request request,
    _Context context,
    _Target target,
  ) async {
    if (target.kind != _Kind.event) return _status(405);
    final collection = _collection(context, target);
    if (collection == null) return _status(404);
    final id = target.eventId!;
    final memberId = context.member.id;
    final stored = records.get(collection.records, id);
    final live = stored != null && !stored.deleted;
    if (live && !RecordStore.canSee(stored, memberId)) return _status(403);
    if (live && !_isExposed(context, collection, stored)) return _status(403);

    final ifNoneMatch = request.headers['if-none-match'];
    final ifMatch = request.headers['if-match'];
    if (ifNoneMatch == '*' && live) return _status(412);
    if (ifMatch != null &&
        ifMatch != '*' &&
        (!live || ifMatch != _etag(stored))) {
      return _status(412);
    }
    if (ifMatch == '*' && !live) return _status(412);

    final text = await _text(request);
    if (collection.todos) {
      return _putTodo(
        context,
        collection,
        id,
        stored: live ? stored : null,
        text: text,
      );
    }
    final existing = live ? CalendarEvent.fromRecord(stored) : null;
    final parsed = parseEventIcs(
      text,
      id: id,
      location: location(),
      existing: existing,
      allowConfidential: context.password.includeConfidential,
    );
    final event = parsed.event;
    if (event == null) {
      return _davError(
        403,
        '<c:valid-calendar-object-resource/>',
        message:
            '${parsed.unsupported ?? 'Nicht unterstützt'} – bitte den Termin '
            'in Famio anlegen.',
      );
    }
    final audience = live ? stored.visibleTo : null;
    final now = DateTime.now().millisecondsSinceEpoch;
    SyncRecord recordOf(CalendarEvent e, {SyncRecord? previous}) => SyncRecord(
      collection: Collections.events,
      id: e.id,
      data: {...e.toData(), SyncRecord.visibilityKey: ?audience},
      updatedAt: max(now, (previous?.updatedAt ?? 0) + 1),
    );
    final rejected = records.writeAs(memberId, [
      recordOf(event, previous: stored),
      for (final d in parsed.detached)
        recordOf(d, previous: records.get(Collections.events, d.id)),
    ]);
    if (rejected.any((r) => r.id == id)) return _status(409);
    onChanged();
    // No ETag: the stored event differs from what was sent (Famio keeps
    // only what it understands), so the client fetches it again.
    return Response(live ? 204 : 201);
  }

  /// A task or shopping item from a reminder app.
  Response _putTodo(
    _Context context,
    _Collection collection,
    String id, {
    required SyncRecord? stored,
    required String text,
  }) {
    final todo = parseTodoIcs(text, location: location());
    if (todo == null) {
      return _davError(
        403,
        '<c:valid-calendar-object-resource/>',
        message: 'Diese Liste nimmt nur Aufgaben (VTODO) an.',
      );
    }
    final data = switch (collection.kind) {
      _Content.tasks => taskDataFrom(
        todo,
        stored == null ? null : Task.fromRecord(stored),
      ),
      _ => shoppingItemDataFrom(
        todo,
        collection.listId!,
        stored == null ? null : ShoppingItem.fromRecord(stored),
      ),
    };
    final audience = stored?.visibleTo;
    final rejected = records.writeAs(context.member.id, [
      SyncRecord(
        collection: collection.records,
        id: id,
        data: {...data, SyncRecord.visibilityKey: ?audience},
        updatedAt: max(
          DateTime.now().millisecondsSinceEpoch,
          (stored?.updatedAt ?? 0) + 1,
        ),
      ),
    ]);
    if (rejected.any((r) => r.id == id)) return _status(409);
    if (collection.kind == _Content.tasks) {
      advanceRepeatingTasks(records, [id], location: location());
    }
    onRecordsChanged?.call();
    return Response(stored != null ? 204 : 201);
  }

  Response _delete(Request request, _Context context, _Target target) {
    if (target.kind != _Kind.event) return _status(403);
    final collection = _collection(context, target);
    final r = collection == null
        ? null
        : _exposedRecord(context, collection, target.eventId!);
    if (collection == null || r == null) return _status(404);
    final ifMatch = request.headers['if-match'];
    if (ifMatch != null && ifMatch != '*' && ifMatch != _etag(r)) {
      return _status(412);
    }
    final rejected = records.writeAs(context.member.id, [
      SyncRecord(
        collection: collection.records,
        id: r.id,
        data: const {},
        deleted: true,
        updatedAt: max(DateTime.now().millisecondsSinceEpoch, r.updatedAt + 1),
      ),
    ]);
    if (rejected.isNotEmpty) return _status(403);
    collection.todos ? onRecordsChanged?.call() : onChanged();
    return Response(204);
  }

  /// Apps set color and order of the calendar; Famio keeps its own, but
  /// answers as if accepted so the apps do not report an error.
  Future<Response> _proppatch(Request request, _Target target) async {
    final body = await _xmlBody(request);
    final names = [
      for (final e
          in body?.rootElement.findAllElements('prop', namespaceUri: _dav) ??
              const <XmlElement>[])
        for (final p in e.childElements)
          (p.name.namespaceUri ?? '', p.name.local),
    ];
    final href = '/${target.path}';
    return _multistatus(
      '<d:response><d:href>${_esc(href)}</d:href><d:propstat><d:prop>'
      '${names.map((n) => _emptyElement(n)).join()}'
      '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
    );
  }

  // --- data -----------------------------------------------------------------

  /// The collections [c] sees in their calendar home.
  List<_Collection> _collections(_Context c) => [
    const _Collection(_Content.events, CalDavServer.calendarSlug),
    const _Collection(_Content.tasks, CalDavServer.tasksSlug),
    for (final list in records.all(
      Collections.shoppingLists,
      visibleToMember: c.member.id,
    ))
      if (!list.deleted && _validListId(list.id))
        _Collection(
          _Content.shopping,
          '${CalDavServer.shoppingPrefix}${list.id}',
          listId: list.id,
        ),
  ];

  /// The collection [target] is in, if it exists for [c].
  _Collection? _collection(_Context c, _Target target) {
    final slug = target.slug;
    if (slug == null) return null;
    if (slug == CalDavServer.calendarSlug) {
      return const _Collection(_Content.events, CalDavServer.calendarSlug);
    }
    if (slug == CalDavServer.tasksSlug) {
      return const _Collection(_Content.tasks, CalDavServer.tasksSlug);
    }
    if (!slug.startsWith(CalDavServer.shoppingPrefix)) return null;
    final listId = slug.substring(CalDavServer.shoppingPrefix.length);
    final list = records.get(Collections.shoppingLists, listId);
    if (list == null ||
        list.deleted ||
        !RecordStore.canSee(list, c.member.id)) {
      return null;
    }
    return _Collection(_Content.shopping, slug, listId: listId);
  }

  static bool _validListId(String id) =>
      _Target._validId.hasMatch('${CalDavServer.shoppingPrefix}$id');

  String? _shoppingListName(String listId) {
    final list = records.get(Collections.shoppingLists, listId);
    return list == null ? null : ShoppingList.fromRecord(list).name;
  }

  /// Change tag of [collection]: shopping lists also change with their
  /// name.
  int _collectionRev(_Context c, _Collection collection) {
    final rev = records.collectionRev(collection.records, c.member.id);
    if (collection.kind != _Content.shopping) return rev;
    return max(
      rev,
      records.collectionRev(Collections.shoppingLists, c.member.id),
    );
  }

  static bool _onList(SyncRecord r, _Collection collection) =>
      r.data['listId'] == collection.listId;

  bool _isExposed(_Context c, _Collection collection, SyncRecord r) =>
      !r.deleted &&
      RecordStore.canSee(r, c.member.id) &&
      switch (collection.kind) {
        _Content.events =>
          c.password.includeConfidential || r.data['confidential'] != true,
        _Content.tasks => true,
        _Content.shopping => _onList(r, collection),
      };

  List<SyncRecord> _exposed(_Context c, _Collection collection) => [
    for (final r in records.all(
      collection.records,
      visibleToMember: c.member.id,
    ))
      if (_isExposed(c, collection, r)) r,
  ];

  SyncRecord? _exposedRecord(_Context c, _Collection collection, String id) {
    final r = records.get(collection.records, id);
    return r != null && _isExposed(c, collection, r) ? r : null;
  }

  String _ics(SyncRecord r, _Collection collection) =>
      switch (collection.kind) {
        _Content.events => eventToIcs(
          CalendarEvent.fromRecord(r),
          location: location(),
          updatedAt: r.updatedAt,
        ),
        _Content.tasks => taskToIcs(r, location: location()),
        _Content.shopping => shoppingItemToIcs(r, location: location()),
      };

  static String _etag(SyncRecord r) => '"${r.rev}"';

  // --- hrefs ----------------------------------------------------------------

  static String _principalHref(String user) =>
      '/dav/principals/${Uri.encodeComponent(user)}/';

  static String _homeHref(String user) =>
      '/dav/calendars/${Uri.encodeComponent(user)}/';

  static String _collectionHref(String user, _Collection c) =>
      '${_homeHref(user)}${Uri.encodeComponent(c.slug)}/';

  static String _resourceHref(String user, _Collection c, String id) =>
      '${_collectionHref(user, c)}${Uri.encodeComponent(id)}.ics';

  static String? _resourceIdFromHref(
    String href,
    String user,
    _Collection collection,
  ) {
    final path = Uri.tryParse(href)?.pathSegments;
    if (path == null) return null;
    final target = _Target.parse([
      for (final s in path.skip(1))
        if (s.isNotEmpty) s,
    ]);
    if (target?.kind != _Kind.event ||
        target!.user!.toLowerCase() != user.toLowerCase() ||
        target.slug != collection.slug) {
      return null;
    }
    return target.eventId;
  }

  // --- XML ------------------------------------------------------------------

  Future<XmlDocument?> _xmlBody(Request request) async {
    final text = await _text(request);
    return text.trim().isEmpty ? null : XmlDocument.parse(text);
  }

  static Future<String> _text(Request request) async {
    final length = request.contentLength;
    if (length != null && length > _maxBody) {
      throw _DavError(_status(413, 'Anfrage ist zu groß'));
    }
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBody) {
        throw _DavError(_status(413, 'Anfrage ist zu groß'));
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// One `<response>` with found properties (200) and unknown ones (404).
  static String _response(
    String href,
    Map<(String, String), String> available,
    List<(String, String)>? wanted,
  ) {
    final names = wanted ?? available.keys.toList();
    final found = StringBuffer();
    final missing = StringBuffer();
    for (final name in names) {
      final value = available[name];
      if (value == null) {
        missing.write(_emptyElement(name));
      } else {
        found.write(_element(name, value));
      }
    }
    final out = StringBuffer('<d:response><d:href>${_esc(href)}</d:href>');
    if (found.isNotEmpty) {
      out.write(
        '<d:propstat><d:prop>$found</d:prop>'
        '<d:status>HTTP/1.1 200 OK</d:status></d:propstat>',
      );
    }
    if (missing.isNotEmpty) {
      out.write(
        '<d:propstat><d:prop>$missing</d:prop>'
        '<d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>',
      );
    }
    out.write('</d:response>');
    return out.toString();
  }

  static String _statusResponse(String href, int status) =>
      '<d:response><d:href>${_esc(href)}</d:href>'
      '<d:status>HTTP/1.1 $status ${_reason(status)}</d:status></d:response>';

  static String _element((String, String) name, String content) {
    final (ns, local) = name;
    final prefix = _prefixes[ns];
    if (prefix != null) return '<$prefix:$local>$content</$prefix:$local>';
    return '<x:$local xmlns:x="${_esc(ns)}">$content</x:$local>';
  }

  static String _emptyElement((String, String) name) {
    final (ns, local) = name;
    final prefix = _prefixes[ns];
    if (prefix != null) return '<$prefix:$local/>';
    return '<x:$local xmlns:x="${_esc(ns)}"/>';
  }

  static String _hrefXml(String href) => '<d:href>${_esc(href)}</d:href>';

  static Response _multistatus(String responses) => Response(
    207,
    body:
        '<?xml version="1.0" encoding="utf-8"?>'
        '<d:multistatus ${_namespaces()}>$responses</d:multistatus>',
    headers: {'content-type': 'application/xml; charset=utf-8'},
  );

  static String _namespaces() =>
      _prefixes.entries.map((e) => 'xmlns:${e.value}="${e.key}"').join(' ');

  static Response _davError(
    int status,
    String condition, {
    String? message,
  }) => Response(
    status,
    body:
        '<?xml version="1.0" encoding="utf-8"?>'
        '<d:error ${_namespaces()}>$condition'
        '${message == null ? '' : '<d:responsedescription>${_esc(message)}</d:responsedescription>'}'
        '</d:error>',
    headers: {'content-type': 'application/xml; charset=utf-8'},
  );

  static Response _status(int status, [String? message]) => Response(
    status,
    body: message ?? _reason(status),
    headers: {'content-type': 'text/plain; charset=utf-8'},
  );

  static String _reason(int status) => switch (status) {
    200 => 'OK',
    400 => 'Bad Request',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    409 => 'Conflict',
    412 => 'Precondition Failed',
    413 => 'Payload Too Large',
    _ => 'Error',
  };

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _httpDate(DateTime t) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    String two(int v) => v.toString().padLeft(2, '0');
    return '${days[t.weekday - 1]}, ${two(t.day)} ${months[t.month - 1]} '
        '${t.year} ${two(t.hour)}:${two(t.minute)}:${two(t.second)} GMT';
  }
}

class _Context {
  _Context(this.member, this.password);

  final FamilyMember member;
  final AppPassword password;
}

class _DavError implements Exception {
  _DavError(this.response);

  final Response response;
}

enum _Kind { root, principals, principal, home, calendar, event }

/// What a collection holds.
enum _Content { events, tasks, shopping }

/// A collection in a member's calendar home.
class _Collection {
  const _Collection(this.kind, this.slug, {this.listId});

  final _Content kind;
  final String slug;

  /// The shopping list of a [_Content.shopping] collection.
  final String? listId;

  bool get todos => kind != _Content.events;

  /// The record collection behind it.
  String get records => switch (kind) {
    _Content.events => Collections.events,
    _Content.tasks => Collections.tasks,
    _Content.shopping => Collections.shoppingItems,
  };
}

/// What a path below `/dav/` points to.
class _Target {
  _Target(this.kind, this.path, {this.user, this.slug, this.eventId});

  final _Kind kind;
  final String path;
  final String? user;

  /// The collection (calendar or to-do list) for [_Kind.calendar] and
  /// [_Kind.event].
  final String? slug;

  /// The resource (event, task or item) for [_Kind.event].
  final String? eventId;

  static final _validId = RegExp(r'^[A-Za-z0-9._@~+-]{1,64}$');
  static final _validSlug = RegExp(r'^[A-Za-z0-9._~+-]{1,80}$');

  /// [parts] are the decoded segments after `dav`.
  static _Target? parse(List<String> parts) {
    final path = ['dav', ...parts.map(Uri.encodeComponent)].join('/');
    switch (parts) {
      case []:
        return _Target(_Kind.root, '$path/');
      case ['principals']:
        return _Target(_Kind.principals, '$path/');
      case ['principals', final user]:
        return _Target(_Kind.principal, '$path/', user: user);
      case ['calendars', final user]:
        return _Target(_Kind.home, '$path/', user: user);
      case ['calendars', final user, final slug] when _validSlug.hasMatch(slug):
        return _Target(_Kind.calendar, '$path/', user: user, slug: slug);
      case ['calendars', final user, final slug, final file]
          when _validSlug.hasMatch(slug) && file.toLowerCase().endsWith('.ics'):
        final id = file.substring(0, file.length - 4);
        if (!_validId.hasMatch(id)) return null;
        return _Target(_Kind.event, path, user: user, slug: slug, eventId: id);
      default:
        return null;
    }
  }
}

/// The parts of a calendar-query filter Famio evaluates: the component and
/// an optional time range. Everything else matches.
class _QueryFilter {
  _QueryFilter(this.component, this.start, this.end);

  static _QueryFilter parse(XmlElement root) {
    final filter = root
        .findElements('filter', namespaceUri: _caldav)
        .firstOrNull;
    var component = 'VEVENT';
    DateTime? start;
    DateTime? end;
    final calendar = filter
        ?.findElements('comp-filter', namespaceUri: _caldav)
        .firstOrNull;
    final inner = calendar
        ?.findElements('comp-filter', namespaceUri: _caldav)
        .firstOrNull;
    if (inner != null) {
      component = inner.getAttribute('name')?.toUpperCase() ?? component;
      final range = inner
          .findElements('time-range', namespaceUri: _caldav)
          .firstOrNull;
      start = _utc(range?.getAttribute('start'));
      end = _utc(range?.getAttribute('end'));
    }
    return _QueryFilter(component, start, end);
  }

  final String component;
  final DateTime? start;
  final DateTime? end;

  bool matches(CalendarEvent e) {
    if (start == null && end == null) return true;
    // A day of slack on both sides: all-day events are floating dates.
    final from = (start ?? DateTime.utc(1900)).subtract(
      const Duration(days: 1),
    );
    final to = (end ?? DateTime.utc(2200)).add(const Duration(days: 1));
    return e.occurrencesBetween(from.toLocal(), to.toLocal()).isNotEmpty;
  }

  static DateTime? _utc(String? v) {
    if (v == null) return null;
    final m = RegExp(
      r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$',
    ).firstMatch(v);
    if (m == null) return null;
    int g(int i) => int.parse(m[i]!);
    return DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6));
  }
}
