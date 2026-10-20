part of '../api.dart';

/// Server administration → PhotoVault: the connection to the family's
/// photo library (see [PhotoVaultLink]).
extension _PhotoVaultRoutes on FamioApi {
  PhotoVaultLink get _photoVault =>
      photoVault ??
      (throw ApiException(404, 'not_found', t('Nicht verfügbar')));

  Response _adminPhotoVault(Request request) {
    _admin(request);
    return _json(_photoVault.info());
  }

  /// `{url, name, password}`, then `{vorgang, code}` while PhotoVault asks
  /// for a code.
  Future<Response> _adminConnectPhotoVault(Request request) async {
    final admin = _admin(request);
    final result = await _photoVault.connect(await _body(request));
    if (result['step'] == null) {
      _audit(admin, 'hat Famio mit PhotoVault verbunden');
    }
    return _json(result);
  }

  Future<Response> _adminSavePhotoVault(Request request) async {
    final admin = _admin(request);
    final info = await _photoVault.configure(await _body(request));
    _audit(admin, 'hat die PhotoVault-Anbindung geändert');
    return _json(info);
  }

  Future<Response> _adminDeletePhotoVault(Request request) async {
    final admin = _admin(request);
    final info = await _photoVault.disconnect();
    _audit(admin, 'hat die PhotoVault-Anbindung entfernt');
    return _json(info);
  }

  Future<Response> _adminSyncPhotoVault(Request request) async {
    _admin(request);
    await _photoVault.sync();
    return _json(_photoVault.info());
  }

  Future<Response> _adminPhotoVaultAlbums(Request request) async {
    _admin(request);
    return _json({'albums': await _photoVault.albums()});
  }

  /// A photo's picture, fetched from PhotoVault when a member looks at it
  /// (`?thumb=` gives the thumbnail).
  Future<Response> _photoVaultFile(
    Request request,
    String id,
    FamilyMember member,
  ) async {
    final file = await photoVault?.download(
      id,
      member.id,
      thumbnail: request.url.queryParameters.containsKey('thumb'),
    );
    if (file == null) {
      throw ApiException(404, 'not_found', t('Datei nicht gefunden'));
    }
    return Response.ok(
      file.stream,
      headers: {
        'content-type': file.headers['content-type'] ?? 'image/jpeg',
        'content-length': ?file.contentLength?.toString(),
        'x-content-type-options': 'nosniff',
        'cache-control': 'private, max-age=86400',
      },
    );
  }
}
