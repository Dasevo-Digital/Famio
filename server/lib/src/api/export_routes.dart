part of '../api.dart';

/// Data exports as ZIP: the member's own (what they see) and, for admins,
/// the whole family. Both need the password.
extension _ExportRoutes on FamioApi {
  DataExport get _exports =>
      exports ?? (throw ApiException(404, 'not_found', t('Export fehlt')));

  Future<void> _confirmPassword(Request request, FamilyMember member) async {
    final body = await _body(request);
    final address = clientAddress.of(request);
    _checkThrottle(address, '#pw:${member.id}');
    if (accounts.hasPassword(member.id) &&
        !await accounts.checkPassword(
          member.id,
          body['password'] as String? ?? '',
        )) {
      throttle.failed(address, '#pw:${member.id}');
      throw ApiException(403, 'invalid_credentials', t('Passwort falsch'));
    }
  }

  Response _zip(File file, String name) => Response.ok(
    readAndDelete(file),
    headers: {
      'content-type': 'application/zip',
      'content-length': '${file.lengthSync()}',
      'content-disposition':
          "attachment; filename*=UTF-8''${Uri.encodeComponent(name)}",
      'cache-control': 'no-store',
    },
  );

  static String _today() => DateTime.now().toIso8601String().substring(0, 10);

  Future<Response> _exportMine(Request request) async {
    final member = _auth(request);
    await _confirmPassword(request, member);
    final file = await _exports.member(member);
    _audit(member, 'hat die eigenen Daten exportiert');
    return _zip(file, 'famio-meine-daten-${_today()}.zip');
  }

  Future<Response> _exportFamily(Request request) async {
    final admin = _admin(request);
    await _confirmPassword(request, admin);
    final file = await _exports.family();
    _audit(admin, 'hat alle Daten der Familie exportiert');
    return _zip(file, 'famio-familie-${_today()}.zip');
  }
}
