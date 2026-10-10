part of '../api.dart';

/// Server administration → PaperBuddy: the connection to the family's
/// document archive (see [PaperBuddyLink]).
extension _PaperBuddyRoutes on FamioApi {
  PaperBuddyLink get _paperBuddy =>
      paperBuddy ??
      (throw ApiException(404, 'not_found', t('Nicht verfügbar')));

  Response _adminPaperBuddy(Request request) {
    _admin(request);
    return _json(_paperBuddy.info());
  }

  Future<Response> _adminSavePaperBuddy(Request request) async {
    final admin = _admin(request);
    final info = await _paperBuddy.configure(await _body(request));
    _audit(admin, 'hat die PaperBuddy-Anbindung gespeichert');
    return _json(info);
  }

  Future<Response> _adminDeletePaperBuddy(Request request) async {
    final admin = _admin(request);
    final info = await _paperBuddy.configure(null);
    _audit(admin, 'hat die PaperBuddy-Anbindung entfernt');
    return _json(info);
  }

  Future<Response> _adminSyncPaperBuddy(Request request) async {
    _admin(request);
    await _paperBuddy.sync();
    return _json(_paperBuddy.info());
  }

  /// A document's file, fetched from PaperBuddy when a member opens it.
  Future<Response> _paperBuddyFile(
    Request request,
    String id,
    FamilyMember member,
  ) async {
    if (request.url.queryParameters.containsKey('thumb')) {
      throw ApiException(404, 'not_found', t('Keine Vorschau verfügbar'));
    }
    final file = await paperBuddy?.download(id, member.id);
    if (file == null) {
      throw ApiException(404, 'not_found', t('Datei nicht gefunden'));
    }
    final record = records.get(
      Collections.externalDocuments,
      id.substring(0, id.indexOf('.')),
    )!;
    final ref = FileRef.fromJson(record.data['file'])!;
    return Response.ok(
      file.stream,
      headers: {
        ..._fileHeaders(ref.name, ref.mime),
        'content-length': ?file.contentLength?.toString(),
        // A new version of the document gets a new id.
        'cache-control': 'private, max-age=31536000, immutable',
      },
    );
  }
}
