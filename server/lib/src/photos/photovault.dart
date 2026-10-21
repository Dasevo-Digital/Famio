import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/timezone.dart' as tz;

import '../accounts.dart';
import '../api_exception.dart';
import '../files/file_store.dart';
import '../i18n.dart';
import '../record_store.dart';

/// The connection to the family's PhotoVault server, set by an admin. Famio
/// signs in once as a PhotoVault account (a device "Famio" there) and keeps
/// only that device's token; it never leaves the Famio server.
class PhotoVaultConfig {
  const PhotoVaultConfig({
    required this.url,
    required this.token,
    this.account = '',
    this.memories = true,
    this.albumId,
    this.albumName = '',
    this.timeline = false,
    this.shareUrl,
    this.sharePassword,
    this.contributeSince,
    this.birthdays = false,
    this.memberIds = const [],
  });

  factory PhotoVaultConfig.fromJson(Map<String, Object?> json) =>
      PhotoVaultConfig(
        url: json['url'] as String? ?? '',
        token: json['token'] as String? ?? '',
        account: json['account'] as String? ?? '',
        memories: json['memories'] as bool? ?? true,
        albumId: json['albumId'] as String?,
        albumName: json['albumName'] as String? ?? '',
        timeline: json['timeline'] as bool? ?? false,
        shareUrl: json['shareUrl'] as String?,
        sharePassword: json['sharePassword'] as String?,
        contributeSince: DateTime.tryParse(
          json['contributeSince'] as String? ?? '',
        ),
        birthdays: json['birthdays'] as bool? ?? false,
        memberIds: [
          for (final m in json['memberIds'] as List? ?? const []) '$m',
        ],
      );

  /// E.g. `https://photos.example.de`.
  final String url;
  final String token;

  /// The PhotoVault account Famio signed in as.
  final String account;

  /// A: "Heute vor einem Jahr" shows PhotoVault's photos of the day.
  final bool memories;

  /// A: the album the wall display shows.
  final String? albumId;
  final String albumName;

  /// A: random photos of the whole timeline on the wall display.
  final bool timeline;

  /// B: a PhotoVault share link that takes contributions; photos of the
  /// family chat go there, to be accepted in PhotoVault.
  final String? shareUrl;
  final String? sharePassword;

  /// B: only photos sent from then on.
  final DateTime? contributeSince;

  /// C: birthdays from the family tree (those not noted elsewhere).
  final bool birthdays;

  /// Who sees the photos and birthdays; empty: every member but guests.
  final List<String> memberIds;

  PhotoVaultConfig copyWith({
    String? url,
    String? token,
    String? account,
    bool? memories,
    String? Function()? albumId,
    String? albumName,
    bool? timeline,
    String? Function()? shareUrl,
    String? Function()? sharePassword,
    DateTime? Function()? contributeSince,
    bool? birthdays,
    List<String>? memberIds,
  }) => PhotoVaultConfig(
    url: url ?? this.url,
    token: token ?? this.token,
    account: account ?? this.account,
    memories: memories ?? this.memories,
    albumId: albumId == null ? this.albumId : albumId(),
    albumName: albumName ?? this.albumName,
    timeline: timeline ?? this.timeline,
    shareUrl: shareUrl == null ? this.shareUrl : shareUrl(),
    sharePassword: sharePassword == null ? this.sharePassword : sharePassword(),
    contributeSince: contributeSince == null
        ? this.contributeSince
        : contributeSince(),
    birthdays: birthdays ?? this.birthdays,
    memberIds: memberIds ?? this.memberIds,
  );

  Map<String, Object?> toJson() => {
    'url': url,
    'token': token,
    'account': account,
    'memories': memories,
    'albumId': albumId,
    'albumName': albumName,
    'timeline': timeline,
    'shareUrl': shareUrl,
    'sharePassword': sharePassword,
    'contributeSince': contributeSince?.toUtc().toIso8601String(),
    'birthdays': birthdays,
    'memberIds': memberIds,
  };
}

/// A birthday of the family tree Famio left out, and why.
typedef SkippedBirthday = ({String name, String birthday, String reason});

/// PhotoVault for the family (issue #218):
///
/// - A: the photos PhotoVault remembers for today (`/api/v1/rueckblick`)
///   in "Heute vor einem Jahr", and an album or random photos of the whole
///   timeline as the wall display's slideshow – all in `external_photos`;
///   the files stay in PhotoVault, Famio fetches a picture when a member
///   opens it.
/// - B: photos of the family chat (never direct messages) go to a
///   PhotoVault share link that takes contributions; they are accepted or
///   refused in PhotoVault.
/// - C: birthdays of the people in PhotoVault's family tree, in
///   `external_birthdays` – unless the family has them already (a member,
///   child or contact on that day with the name, or a calendar entry that
///   names them or a birthday on that day).
class PhotoVaultLink {
  PhotoVaultLink({
    required this.db,
    required this.records,
    required this.accounts,
    required this.files,
    required this.location,
    required this.onChanged,
    http.Client? client,
    this.interval = const Duration(minutes: 15),
    DateTime Function()? now,
  }) : _http = client ?? http.Client(),
       _now = now ?? DateTime.now;

  final Database db;
  final RecordStore records;
  final Accounts accounts;
  final FileStore files;

  /// The family's time zone: "today" is theirs, not the server's.
  final tz.Location Function() location;
  final void Function() onChanged;
  final Duration interval;
  final http.Client _http;
  final DateTime Function() _now;
  Timer? _timer;
  Future<void>? _running;

  /// The share link's session (password), while it lasts.
  String? _shareCookie;

  static const _key = 'photovault';
  static const _statusKey = 'photovault.status';
  static const _sentKey = 'photovault.sent';
  static const _timelineKey = 'photovault.timeline';
  static const idPrefix = 'pv-';

  /// At most this many album photos on the wall display.
  static const albumLimit = 300;

  /// Random photos of the timeline on the wall display, drawn anew every
  /// [timelineEvery].
  static const timelineCount = 100;
  static const timelineEvery = Duration(hours: 3);

  /// Photos of the chat sent to PhotoVault per run.
  static const contributeLimit = 50;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => sync());
    if (config != null) unawaited(sync());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  PhotoVaultConfig? get config {
    final raw = _setting(_key);
    return raw == null
        ? null
        : PhotoVaultConfig.fromJson((raw as Map).cast<String, Object?>());
  }

  /// What the admin screen shows; never token or password.
  Map<String, Object?> info() {
    final c = config;
    return {
      'connected': c != null,
      if (c != null) ...{
        'url': c.url,
        'account': c.account,
        'memories': c.memories,
        'albumId': c.albumId,
        'albumName': c.albumName,
        'timeline': c.timeline,
        'shareUrl': c.shareUrl,
        'sharePassword': c.sharePassword != null,
        'birthdays': c.birthdays,
        'memberIds': c.memberIds,
      },
      ...?(_setting(_statusKey) as Map?)?.cast<String, Object?>(),
    };
  }

  // --- connecting ------------------------------------------------------------

  /// Signs in to PhotoVault (`{url, name, password}`, then `{vorgang,
  /// code}` if it asks for a code) and keeps the device token. Returns the
  /// info, or `{step: 'totp', vorgang}` while the code is missing.
  Future<Map<String, Object?>> connect(Map<String, Object?> body) async {
    final url = _url('${body['url'] ?? config?.url ?? ''}');
    final Map<String, Object?> answer;
    if (body['vorgang'] case final String vorgang) {
      answer = await _post(url, null, '/api/v1/anmelden/totp', {
        'vorgang': vorgang,
        'code': '${body['code'] ?? ''}'.replaceAll(' ', ''),
      });
    } else {
      answer = await _post(url, null, '/api/v1/anmelden', {
        'name': '${body['name'] ?? ''}'.trim(),
        'passwort': '${body['password'] ?? ''}',
        'geraet': 'Famio',
      });
    }
    switch (answer['schritt']) {
      case 'totp':
        return {'step': 'totp', 'vorgang': answer['vorgang']};
      case 'totp_einrichten':
        throw ApiException.badRequest(
          'photovault_totp_setup',
          t(
            'Das PhotoVault-Konto muss erst in PhotoVault die '
            'Zwei-Faktor-Anmeldung einrichten.',
          ),
        );
    }
    final token = answer['token'];
    if (token is! String || token.isEmpty) {
      throw ApiException.badRequest(
        'photovault_error',
        t('Unter dieser Adresse antwortet kein PhotoVault.'),
      );
    }
    final me = await _get(url, token, '/api/v1/konto');
    final before = config;
    final c = (before ?? PhotoVaultConfig(url: url, token: token)).copyWith(
      url: url,
      token: token,
      account: '${me['name'] ?? body['name'] ?? ''}',
    );
    // The device of a former connection is signed out there.
    if (before != null && before.token != token) {
      unawaited(_signOut(before));
    }
    _put(_key, c.toJson());
    await sync();
    return info();
  }

  /// Saves what PhotoVault brings into Famio (memories, album, share link,
  /// birthdays, audience) and syncs.
  Future<Map<String, Object?>> configure(Map<String, Object?> body) async {
    final c = config;
    if (c == null) {
      throw ApiException.badRequest(
        'photovault_not_connected',
        t('Erst mit PhotoVault verbinden.'),
      );
    }
    var next = c.copyWith(
      memories: body['memories'] as bool? ?? c.memories,
      birthdays: body['birthdays'] as bool? ?? c.birthdays,
      timeline: body['timeline'] as bool? ?? c.timeline,
      memberIds: body.containsKey('memberIds')
          ? [
              for (final m in body['memberIds'] as List? ?? const [])
                if (accounts.byId('$m') != null) '$m',
            ]
          : c.memberIds,
    );
    if (body.containsKey('albumId')) {
      final id = body['albumId'] as String?;
      String name = '';
      if (id != null && id.isNotEmpty) {
        final album = (await albums(
          next,
        )).where((a) => a['id'] == id).firstOrNull;
        if (album == null) {
          throw ApiException.badRequest(
            'photovault_album',
            t('Dieses Album gibt es in PhotoVault nicht.'),
          );
        }
        name = '${album['name'] ?? ''}';
      }
      next = next.copyWith(
        albumId: () => id == null || id.isEmpty ? null : id,
        albumName: name,
      );
    }
    if (body.containsKey('shareUrl')) {
      final link = '${body['shareUrl'] ?? ''}'.trim();
      final password = switch (body['sharePassword']) {
        final String p when p.isNotEmpty => p,
        _ => link == c.shareUrl ? c.sharePassword : null,
      };
      if (link.isEmpty) {
        next = next.copyWith(
          shareUrl: () => null,
          sharePassword: () => null,
          contributeSince: () => null,
        );
      } else {
        _shareCookie = null;
        await _checkShare(link, password);
        next = next.copyWith(
          shareUrl: () => link,
          sharePassword: () => password,
          contributeSince: () => link == c.shareUrl && c.contributeSince != null
              ? c.contributeSince
              : _now().toUtc(),
        );
      }
    }
    _put(_key, next.toJson());
    await sync();
    return info();
  }

  /// Removes the connection, signs Famio's device out of PhotoVault and
  /// deletes the photos and birthdays it brought.
  Future<Map<String, Object?>> disconnect() async {
    final c = config;
    db.execute('DELETE FROM settings WHERE key IN (?, ?, ?, ?)', [
      _key,
      _statusKey,
      _sentKey,
      _timelineKey,
    ]);
    _shareCookie = null;
    if (c != null) unawaited(_signOut(c));
    final changed = _storePhotos(const {}, c) | _storeBirthdays(const [], c);
    if (changed) onChanged();
    return info();
  }

  Future<void> _signOut(PhotoVaultConfig c) async {
    try {
      await _post(c.url, c.token, '/api/v1/abmelden', const {});
    } on Object {
      // Then it stays in PhotoVault's device list, to remove there.
    }
  }

  /// PhotoVault's albums, for choosing the wall display's.
  Future<List<Map<String, Object?>>> albums([PhotoVaultConfig? c]) async {
    final cfg = c ?? config;
    if (cfg == null) return const [];
    final json = await _get(cfg.url, cfg.token, '/api/v1/alben');
    return [
      for (final a in json['alben'] as List? ?? const [])
        if (a is Map)
          {
            'id': '${a['id']}',
            'name': '${a['name'] ?? ''}',
            'count': a['anzahl'],
          },
    ];
  }

  // --- syncing ---------------------------------------------------------------

  /// Fetches memories, wall photos and birthdays, sends new chat photos; runs
  /// never overlap.
  Future<void> sync() =>
      _running ??= _sync().whenComplete(() => _running = null);

  Future<void> _sync() async {
    final c = config;
    if (c == null) return;
    final status = <String, Object?>{
      ...?(_setting(_statusKey) as Map?)?.cast<String, Object?>(),
    };
    try {
      final photos = <String, _Photo>{};
      final today = _today();
      if (c.memories) {
        final json = await _get(c.url, c.token, '/api/v1/rueckblick', {
          'heute': dayKey(today),
        });
        for (final m in json['letzte'] as List? ?? const []) {
          if (m is! Map || m['tag'] != dayKey(today)) continue;
          for (final a in _images(m['aufnahmen'])) {
            photos[a.id] = a.copyWith(
              memoryOf: dayKey(today),
              yearsAgo: (m['jahreHer'] as num?)?.toInt(),
            );
          }
        }
      }
      if (c.albumId case final album?) {
        final json = await _get(c.url, c.token, '/api/v1/alben/$album');
        final images = _images(json['aufnahmen']).toList()
          ..sort((a, b) => b.takenAt.compareTo(a.takenAt));
        for (final a in images.take(albumLimit)) {
          photos[a.id] = (photos[a.id] ?? a).copyWith(album: true);
        }
      }
      if (c.timeline) {
        for (final a in await _timeline(c)) {
          photos[a.id] = (photos[a.id] ?? a).copyWith(album: true);
        }
      } else {
        db.execute('DELETE FROM settings WHERE key = ?', [_timelineKey]);
      }
      var birthdays = const <_Birthday>[];
      var skipped = const <SkippedBirthday>[];
      if (c.birthdays) {
        (birthdays, skipped) = await _birthdays(c);
      }
      final changed = _storePhotos(photos, c) | _storeBirthdays(birthdays, c);
      if (changed) onChanged();
      final sent = c.shareUrl == null ? 0 : await _contribute(c);
      status
        ..['lastSync'] = _now().toUtc().toIso8601String()
        ..['memoryCount'] = photos.values
            .where((p) => p.memoryOf != null)
            .length
        ..['albumCount'] = photos.values.where((p) => p.album).length
        ..['birthdayCount'] = birthdays.length
        ..['skippedBirthdays'] = [
          for (final s in skipped)
            {'name': s.name, 'birthday': s.birthday, 'reason': s.reason},
        ]
        ..['sentTotal'] = ((status['sentTotal'] as num?)?.toInt() ?? 0) + sent
        ..['lastError'] = null;
    } on ApiException catch (e) {
      status['lastError'] = e.message;
    } on Exception catch (e) {
      status['lastError'] = t('Keine Verbindung zu PhotoVault ({error}).', {
        'error': '$e',
      });
    }
    _put(_statusKey, status);
  }

  /// [timelineCount] random photos of PhotoVault's whole timeline, the
  /// same ones for [timelineEvery]. PhotoVault cannot sort by chance, so
  /// Famio asks how many photos there are and then for the one at each of
  /// some random places of the timeline (oldest first); videos are left
  /// out. Locked photos and the trash are not part of the timeline.
  Future<List<_Photo>> _timeline(PhotoVaultConfig c) async {
    final source = '${c.url}|${c.account}';
    final kept = (_setting(_timelineKey) as Map?)?.cast<String, Object?>();
    final drawn = DateTime.tryParse('${kept?['drawnAt'] ?? ''}');
    if (kept != null &&
        kept['source'] == source &&
        drawn != null &&
        _now().difference(drawn) < timelineEvery) {
      return _images(kept['photos']).toList();
    }
    final library = await _get(c.url, c.token, '/api/v1/bibliothek');
    final count = (library['aufnahmen'] as num?)?.toInt() ?? 0;
    final random = Random();
    final tried = <int>{};
    final picked = <String, Map<String, Object?>>{};
    // Room for the videos among them.
    final places = min(count, timelineCount * 2);
    while (picked.length < timelineCount && tried.length < places) {
      final at = random.nextInt(count);
      if (!tried.add(at)) continue;
      final json = await _get(c.url, c.token, '/api/v1/aufnahmen', {
        'sortierung': 'aufnahmeAlt',
        'anzahl': '1',
        'nach': 'o:$at',
      });
      for (final a in json['aufnahmen'] as List? ?? const []) {
        if (a is Map && a['art'] == 'bild' && a['id'] != null) {
          picked['${a['id']}'] = {
            'id': a['id'],
            'art': 'bild',
            'name': a['name'],
            'aufgenommen': a['aufgenommen'],
          };
        }
      }
    }
    _put(_timelineKey, {
      'source': source,
      'drawnAt': _now().toUtc().toIso8601String(),
      'photos': picked.values.toList(),
    });
    return _images(picked.values.toList()).toList();
  }

  DateTime _today() {
    final n = tz.TZDateTime.from(_now(), location());
    return DateTime(n.year, n.month, n.day);
  }

  Iterable<_Photo> _images(Object? list) sync* {
    for (final a in list as List? ?? const []) {
      if (a is! Map || a['art'] != 'bild' || a['id'] == null) continue;
      yield _Photo(
        id: '${a['id']}',
        name: '${a['name'] ?? 'foto.jpg'}',
        takenAt:
            DateTime.tryParse('${a['aufgenommen'] ?? ''}') ?? DateTime(2000),
      );
    }
  }

  /// Every member but guests, or those the admin chose.
  List<String> _audience(PhotoVaultConfig? c) =>
      switch (c?.memberIds ?? const <String>[]) {
        final ids when ids.isNotEmpty => ids,
        _ => [
          for (final m in accounts.members())
            if (m.role != MemberRole.guest) m.id,
        ],
      };

  bool _storePhotos(Map<String, _Photo> photos, PhotoVaultConfig? c) {
    final audience = _audience(c);
    final wanted = {for (final p in photos.values) '$idPrefix${p.id}': p};
    return records.writeAsServer([
      for (final MapEntry(key: id, value: p) in wanted.entries)
        SyncRecord(
          collection: Collections.externalPhotos,
          id: id,
          data: {...p.toData(id), SyncRecord.visibilityKey: audience},
          updatedAt: 0,
        ),
      for (final r in records.all(Collections.externalPhotos))
        if (!wanted.containsKey(r.id) && !r.deleted)
          SyncRecord(
            collection: r.collection,
            id: r.id,
            data: const {},
            updatedAt: 0,
            deleted: true,
          ),
    ]);
  }

  bool _storeBirthdays(List<_Birthday> birthdays, PhotoVaultConfig? c) {
    final audience = _audience(c);
    final wanted = {for (final b in birthdays) '$idPrefix${b.personId}': b};
    return records.writeAsServer([
      for (final MapEntry(key: id, value: b) in wanted.entries)
        SyncRecord(
          collection: Collections.externalBirthdays,
          id: id,
          data: {
            'name': b.name,
            'birthday': b.birthday.toString(),
            'source': 'photovault',
            SyncRecord.visibilityKey: audience,
          },
          updatedAt: 0,
        ),
      for (final r in records.all(Collections.externalBirthdays))
        if (!wanted.containsKey(r.id) && !r.deleted)
          SyncRecord(
            collection: r.collection,
            id: r.id,
            data: const {},
            updatedAt: 0,
            deleted: true,
          ),
    ]);
  }

  // --- C: birthdays ----------------------------------------------------------

  /// The living people of the family tree with a birthday, without those
  /// the family has noted somewhere already.
  Future<(List<_Birthday>, List<SkippedBirthday>)> _birthdays(
    PhotoVaultConfig c,
  ) async {
    final json = await _get(c.url, c.token, '/api/v1/stammbaum');
    final known = _knownBirthdays();
    final keep = <_Birthday>[];
    final skipped = <SkippedBirthday>[];
    for (final p in json['personen'] as List? ?? const []) {
      if (p is! Map || p['verwandt'] != true || p['tod'] != null) continue;
      final born = DateTime.tryParse('${p['geburt'] ?? ''}');
      final name = '${p['name'] ?? ''}'.trim();
      if (born == null || name.isEmpty || p['id'] == null) continue;
      final birthday = Birthday(born.month, born.day, born.year);
      final noted = noteOf(name, birthday, known);
      if (noted != null) {
        skipped.add((name: name, birthday: '$birthday', reason: noted));
      } else {
        keep.add(
          _Birthday(personId: '${p['id']}', name: name, birthday: birthday),
        );
      }
    }
    return (keep, skipped);
  }

  /// Every birthday the family has in Famio: members, children, contacts
  /// and calendar entries (own and from connected calendars) on a day.
  List<KnownBirthday> _knownBirthdays() {
    final out = <KnownBirthday>[];
    for (final m in accounts.members()) {
      if (m.birthday case final b?) {
        out.add((
          month: b.month,
          day: b.day,
          text: '${m.displayName} ${m.username}',
          person: true,
          birthdayEntry: false,
          where: t('Mitglied „{name}“', {'name': m.displayName}),
        ));
      }
    }
    for (final r in records.all(Collections.children)) {
      if (r.deleted) continue;
      final c = Child.fromRecord(r);
      out.add((
        month: c.birthDate.month,
        day: c.birthDate.day,
        text: c.name,
        person: true,
        birthdayEntry: false,
        where: t('Kind „{name}“', {'name': c.name}),
      ));
    }
    for (final r in records.all(Collections.contacts)) {
      if (r.deleted) continue;
      final c = FamilyContact.fromRecord(r);
      if (c.birthday case final b?) {
        out.add((
          month: b.month,
          day: b.day,
          text: c.name,
          person: true,
          birthdayEntry: false,
          where: t('Kontakt „{name}“', {'name': c.name}),
        ));
      }
    }
    final calendars = {
      for (final r in records.all(Collections.calendarSubscriptions))
        r.id: '${r.data['name'] ?? ''}',
    };
    for (final collection in [Collections.events, Collections.externalEvents]) {
      for (final r in records.all(collection)) {
        if (r.deleted) continue;
        final e = CalendarEvent.fromRecord(r);
        // A birthday is a day, not an appointment.
        if (!e.allDay) continue;
        final calendar = calendars[e.sourceId];
        out.add((
          month: e.start.month,
          day: e.start.day,
          text: e.title,
          person: false,
          birthdayEntry: _birthdayWords.hasMatch(e.title.toLowerCase()),
          where: calendar == null || calendar.isEmpty
              ? t('Kalender: „{title}“', {'title': e.title})
              : t('Kalender „{calendar}“: „{title}“', {
                  'calendar': calendar,
                  'title': e.title,
                }),
        ));
      }
    }
    return out;
  }

  // --- B: chat photos as contributions --------------------------------------

  /// Sends the family chat's new photos to the share link; returns how
  /// many went.
  Future<int> _contribute(PhotoVaultConfig c) async {
    final since = c.contributeSince;
    final share = _share(c.shareUrl!);
    if (since == null || share == null) return 0;
    final sent = {
      for (final id in _setting(_sentKey) as List? ?? const []) '$id',
    };
    final names = {for (final m in accounts.members()) m.id: m.displayName};
    final candidates = [
      for (final r in records.all(Collections.chatMessages))
        if (!r.deleted && !sent.contains(r.id))
          if (ChatMessage.fromRecord(r) case final m
              when m.chatId == ChatIds.family &&
                  (m.attachment?.isImage ?? false) &&
                  !m.sentAt.isBefore(since))
            m,
    ]..sort((a, b) => a.sentAt.compareTo(b.sentAt));
    var count = 0;
    try {
      for (final m in candidates.take(contributeLimit)) {
        final file = files.get(m.attachment!.id);
        if (file != null) {
          await _upload(c, share, file, m, names[m.authorId]);
          count++;
        }
        sent.add(m.id);
      }
    } finally {
      // The newest ids only: older messages are before [since] anyway.
      final list = sent.toList();
      _put(
        _sentKey,
        list.length > 5000 ? list.sublist(list.length - 5000) : list,
      );
    }
    return count;
  }

  Future<void> _upload(
    PhotoVaultConfig c,
    ({String base, String link}) share,
    StoredFile file,
    ChatMessage m,
    String? author,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final request =
          http.StreamedRequest(
              'POST',
              Uri.parse(
                '${share.base}/api/v1/teilen/${share.link}/beitrag',
              ).replace(
                queryParameters: {
                  'name': file.name,
                  'von': ?author,
                  'geaendert': '${m.sentAt.millisecondsSinceEpoch}',
                },
              ),
            )
            ..headers.addAll({
              'x-pv-teilen': '1',
              'content-type': 'application/octet-stream',
              'cookie': ?_shareCookie,
            })
            ..contentLength = file.size;
      unawaited(
        files
            .read(file)
            .forEach(request.sink.add)
            .whenComplete(request.sink.close),
      );
      final response = await _http
          .send(request)
          .timeout(const Duration(minutes: 5));
      final body = await response.stream.bytesToString();
      if (response.statusCode == 202 || response.statusCode == 200) return;
      if (response.statusCode == 401 &&
          attempt == 0 &&
          c.sharePassword != null) {
        await _shareSession(share, c.sharePassword!);
        continue;
      }
      throw ApiException.badRequest(
        'photovault_contribution',
        t('PhotoVault nimmt das Foto nicht an ({status} {body}).', {
          'status': response.statusCode,
          'body': body.length > 120 ? body.substring(0, 120) : body,
        }),
      );
    }
  }

  /// `https://host/teilen/<link>` → base and link.
  static ({String base, String link})? _share(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    final i = uri.pathSegments.indexOf('teilen');
    if (i < 0 || i + 1 >= uri.pathSegments.length) return null;
    final link = uri.pathSegments[i + 1];
    if (link.isEmpty) return null;
    final prefix = uri.pathSegments.take(i).join('/');
    return (
      base: uri
          .replace(
            path: prefix.isEmpty ? '' : '/$prefix',
            query: '',
            fragment: '',
          )
          .toString()
          .replaceAll(RegExp(r'[?#/]+$'), ''),
      link: link,
    );
  }

  /// The share link must exist and take contributions.
  Future<void> _checkShare(String url, String? password) async {
    final share = _share(url);
    if (share == null) {
      throw ApiException.badRequest(
        'photovault_share',
        t('Das ist kein PhotoVault-Link zum Teilen (…/teilen/…).'),
      );
    }
    Future<http.Response> look() => _http
        .get(
          Uri.parse('${share.base}/api/v1/teilen/${share.link}'),
          headers: {'cookie': ?_shareCookie},
        )
        .timeout(const Duration(seconds: 30));
    var response = await look();
    if (response.statusCode == 401) {
      if (password == null) {
        throw ApiException.badRequest(
          'photovault_share_password',
          t('Der Link ist mit einem Passwort geschützt: bitte eintragen.'),
        );
      }
      await _shareSession(share, password);
      response = await look();
    }
    if (response.statusCode != 200) {
      throw ApiException.badRequest(
        'photovault_share',
        t('PhotoVault kennt diesen Link nicht (mehr).'),
      );
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map || json['hochladen'] != true) {
      throw ApiException.badRequest(
        'photovault_share_closed',
        t(
          'Dieser Link nimmt keine Beiträge an: in PhotoVault beim Teilen '
          '„Beiträge erlauben“ einschalten.',
        ),
      );
    }
  }

  Future<void> _shareSession(
    ({String base, String link}) share,
    String password,
  ) async {
    final response = await _http
        .post(
          Uri.parse('${share.base}/api/v1/teilen/${share.link}/passwort'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'passwort': password}),
        )
        .timeout(const Duration(seconds: 30));
    final cookie = response.headers['set-cookie'];
    if (response.statusCode != 204 || cookie == null) {
      throw ApiException.badRequest(
        'photovault_share_password',
        t('PhotoVault lehnt das Passwort des Links ab.'),
      );
    }
    _shareCookie = cookie.split(';').first;
  }

  // --- A: files ---------------------------------------------------------------

  /// The picture of a photo a member may see: [fileId] as in its record;
  /// a thumbnail (`miniatur`) or the view PhotoVault shows (`ansicht`).
  Future<http.StreamedResponse?> download(
    String fileId,
    String memberId, {
    required bool thumbnail,
  }) async {
    final c = config;
    if (c == null || !fileId.startsWith(idPrefix)) return null;
    final recordId = fileId.substring(0, fileId.lastIndexOf('.'));
    final record = records.get(Collections.externalPhotos, recordId);
    if (record == null ||
        record.deleted ||
        !RecordStore.canSee(record, memberId) ||
        FileRef.fromJson(record.data['file'])?.id != fileId) {
      return null;
    }
    final asset = recordId.substring(idPrefix.length);
    final request = http.Request(
      'GET',
      Uri.parse(
        '${c.url}/api/v1/aufnahmen/${Uri.encodeComponent(asset)}/'
        '${thumbnail ? 'miniatur' : 'ansicht'}',
      ),
    )..headers['authorization'] = 'Bearer ${c.token}';
    final response = await _http.send(request);
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw ApiException(
        502,
        'photovault_error',
        t('PhotoVault antwortet mit Fehler {status}.', {
          'status': response.statusCode,
        }),
      );
    }
    return response;
  }

  // --- PhotoVault API ----------------------------------------------------------

  /// `http(s)://host[:port][/path]` without a trailing slash; only admins
  /// set it (PhotoVault usually runs in the home network).
  static String _url(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ApiException.badRequest(
        'invalid_url',
        t('Die Adresse von PhotoVault beginnt mit http:// oder https://.'),
      );
    }
    return uri
        .replace(query: '', fragment: '')
        .toString()
        .replaceAll(RegExp(r'[?#]+$'), '')
        .replaceAll(RegExp(r'/+$'), '');
  }

  Map<String, Object?> _decode(http.Response response) {
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map) return json.cast();
    } on FormatException {
      // Below.
    }
    throw ApiException.badRequest(
      'photovault_error',
      t('Unter dieser Adresse antwortet kein PhotoVault.'),
    );
  }

  Never _fail(http.Response response) {
    final message = switch (response.statusCode) {
      401 || 403 => t('PhotoVault lehnt die Anmeldung ab.'),
      429 => t('PhotoVault: zu viele Versuche, bitte später noch einmal.'),
      _ => t('PhotoVault antwortet mit Fehler {status}.', {
        'status': response.statusCode,
      }),
    };
    throw ApiException.badRequest('photovault_denied', message);
  }

  Future<Map<String, Object?>> _get(
    String url,
    String token,
    String path, [
    Map<String, String>? query,
  ]) async {
    final response = await _http
        .get(
          Uri.parse('$url$path').replace(queryParameters: query),
          headers: {'authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) _fail(response);
    return _decode(response);
  }

  Future<Map<String, Object?>> _post(
    String url,
    String? token,
    String path,
    Map<String, Object?> body,
  ) async {
    final response = await _http
        .post(
          Uri.parse('$url$path'),
          headers: {
            'content-type': 'application/json',
            'authorization': ?(token == null ? null : 'Bearer $token'),
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) _fail(response);
    return _decode(response);
  }

  // --- settings ----------------------------------------------------------------

  Object? _setting(String key) {
    final row = db.select('SELECT value FROM settings WHERE key = ?', [
      key,
    ]).firstOrNull;
    return row == null ? null : jsonDecode(row['value'] as String);
  }

  void _put(String key, Object? value) => db.execute(
    'INSERT INTO settings (key, value) VALUES (?, ?)'
    ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [key, jsonEncode(value)],
  );
}

/// A birthday Famio knows already, from wherever.
typedef KnownBirthday = ({
  int month,
  int day,

  /// Names or the entry's title.
  String text,

  /// A member, child or contact (not a calendar entry).
  bool person,

  /// A calendar entry called a birthday ("Geburtstag Oma").
  bool birthdayEntry,

  /// Where it is noted, for the admin screen.
  String where,
});

final _birthdayWords = RegExp(
  r'geburtstag|birthday|b-day|bday|cumpleaños|cumpleanos|🎂|\bgeb\.',
);

/// Words of a name worth comparing: three letters or more, folded.
Set<String> _nameWords(String text) {
  const fold = {'ä': 'a', 'ö': 'o', 'ü': 'u', 'ß': 'ss', 'é': 'e', 'á': 'a'};
  final folded = text.toLowerCase().split('').map((c) => fold[c] ?? c).join();
  const ignore = {'geburtstag', 'birthday', 'bday', 'von', 'der', 'die', 'das'};
  return {
    for (final w in folded.split(RegExp(r'[^a-z0-9]+')))
      if (w.length >= 3 && !ignore.contains(w)) w,
  };
}

/// Where the family has [name]'s [birthday] already, or null: an entry on
/// the same day that names them (a word of the name), or a calendar entry
/// on that day called a birthday (it may say "Oma" for "Erna Müller").
String? noteOf(String name, Birthday birthday, List<KnownBirthday> known) {
  final words = _nameWords(name);
  String? sameDay;
  for (final k in known) {
    if (k.month != birthday.month || k.day != birthday.day) continue;
    if (_nameWords(k.text).intersection(words).isNotEmpty) return k.where;
    // Members, children and contacts with another name are other people.
    if (!k.person && k.birthdayEntry) sameDay ??= k.where;
  }
  return sameDay;
}

class _Photo {
  const _Photo({
    required this.id,
    required this.name,
    required this.takenAt,
    this.memoryOf,
    this.yearsAgo,
    this.album = false,
  });

  final String id;
  final String name;
  final DateTime takenAt;

  /// The day it is a memory for ("YYYY-MM-DD"), and how long ago.
  final String? memoryOf;
  final int? yearsAgo;

  /// On the wall display (the album or drawn from the timeline).
  final bool album;

  _Photo copyWith({String? memoryOf, int? yearsAgo, bool? album}) => _Photo(
    id: id,
    name: name,
    takenAt: takenAt,
    memoryOf: memoryOf ?? this.memoryOf,
    yearsAgo: yearsAgo ?? this.yearsAgo,
    album: album ?? this.album,
  );

  Map<String, Object?> toData(String recordId) => {
    'source': 'photovault',
    'takenAt': takenAt.toUtc().toIso8601String(),
    'memoryOf': memoryOf,
    'yearsAgo': yearsAgo,
    'album': album,
    'file': FileRef(
      id: '$recordId.jpg',
      name: name,
      mime: 'image/jpeg',
      size: 0,
    ).toJson(),
  };
}

class _Birthday {
  const _Birthday({
    required this.personId,
    required this.name,
    required this.birthday,
  });

  final String personId;
  final String name;
  final Birthday birthday;
}
