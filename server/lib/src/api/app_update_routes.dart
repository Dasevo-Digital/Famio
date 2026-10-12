part of '../api.dart';

/// App updates through the server (see [AppUpdates]): admins switch the
/// distribution on, every signed-in member's app asks for the package of
/// its platform and downloads it from here.
extension _AppUpdateRoutes on FamioApi {
  AppUpdates get _appUpdates =>
      appUpdates ??
      (throw ApiException(404, 'not_found', t('Nicht verfügbar')));

  Response _adminAppUpdates(Request request) {
    _admin(request);
    return _json(_appUpdates.info());
  }

  Future<Response> _adminSaveAppUpdates(Request request) async {
    final admin = _admin(request);
    final enabled = (await _body(request))['enabled'] == true;
    final info = await _appUpdates.configure(enabled: enabled);
    _audit(
      admin,
      enabled
          ? 'hat App-Updates über den Server eingeschaltet'
          : 'hat App-Updates über den Server ausgeschaltet',
    );
    return _json(info);
  }

  Future<Response> _adminRefreshAppUpdates(Request request) async {
    _admin(request);
    await _appUpdates.prepare();
    return _json(_appUpdates.info());
  }

  AppPackage _appPackage(Request request) {
    _auth(request);
    final platform = AppPlatform.byName(
      request.url.queryParameters['platform'],
    );
    final package = platform == null ? null : appUpdates?.package(platform);
    if (package == null) {
      throw ApiException(404, 'not_found', t('Kein App-Update verfügbar'));
    }
    return package;
  }

  /// The package for `?platform=` (version, size, checksum and the signed
  /// list, which the app checks itself before installing).
  Response _appUpdate(Request request) {
    final package = _appPackage(request);
    return _json({
      'version': package.version,
      'file': package.name,
      'size': package.size,
      'sha256': package.sha256,
      'sums': package.sums,
      'signature': package.signature,
    });
  }

  Response _appUpdateDownload(Request request) {
    final package = _appPackage(request);
    return Response.ok(
      package.file.openRead(),
      headers: {
        ..._fileHeaders(package.name, 'application/octet-stream'),
        'content-length': '${package.size}',
        'cache-control': 'private, max-age=86400',
      },
    );
  }
}
