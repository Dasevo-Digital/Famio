part of '../api.dart';

/// Server administration → Paperless-ngx: the connection to the family's
/// document archive (see [PaperlessLink]).
extension _PaperlessRoutes on FamioApi {
  PaperlessLink get _paperless =>
      paperless ?? (throw ApiException(404, 'not_found', t('Nicht verfügbar')));

  Response _adminPaperless(Request request) {
    _admin(request);
    return _json(_paperless.info());
  }

  Future<Response> _adminSavePaperless(Request request) async {
    final admin = _admin(request);
    final info = await _paperless.configure(await _body(request));
    _audit(admin, 'hat die Paperless-ngx-Anbindung gespeichert');
    return _json(info);
  }

  Future<Response> _adminDeletePaperless(Request request) async {
    final admin = _admin(request);
    final info = await _paperless.configure(null);
    _audit(admin, 'hat die Paperless-ngx-Anbindung entfernt');
    return _json(info);
  }

  Future<Response> _adminSyncPaperless(Request request) async {
    _admin(request);
    await _paperless.sync();
    return _json(_paperless.info());
  }

  /// A document's file, fetched from Paperless-ngx when a member opens it.
  Future<Response> _paperlessFile(
    Request request,
    String id,
    FamilyMember member,
  ) async {
    if (request.url.queryParameters.containsKey('thumb')) {
      throw ApiException(404, 'not_found', t('Keine Vorschau verfügbar'));
    }
    final file = await paperless?.download(id, member.id);
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
