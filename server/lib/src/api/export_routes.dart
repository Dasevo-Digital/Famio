part of '../api.dart';

/// Data exports as ZIP: the member's own (what they see) and, for admins,
/// the whole family. Both need the password.
extension _ExportRoutes on FamioApi {
  DataExport get _exports =>
      exports ?? (throw ApiException(404, 'not_found', t('Export fehlt')));

  /// The member's password from the request ([body] if it was read already).
  /// Accounts without one (single sign-on, service accounts) have nothing to
  /// confirm.
  Future<void> _confirmPassword(
    Request request,
    FamilyMember member, {
    Map<String, Object?>? body,
  }) async {
    body ??= await _body(request);
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
    throttle.succeeded(address, '#pw:${member.id}');
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

  /// Everything on the server, also what is private to others: a backup
  /// for moving servers. So it is for adult admins only, and the other
  /// adults hear of it (#509).
  Future<Response> _exportFamily(Request request) async {
    final admin = _admin(request);
    if (admin.role != MemberRole.adult) {
      throw ApiException(403, 'forbidden', t('Nur für Erwachsene'));
    }
    await _confirmPassword(request, admin);
    final file = await _exports.family();
    _audit(admin, 'hat alle Daten der Familie exportiert');
    final others = {
      for (final m in accounts.members())
        if (m.role == MemberRole.adult && m.id != admin.id) m.id,
    };
    push?.deliver(
      () => PushNotice(
        to: others,
        title: t('Daten der Familie exportiert'),
        body: t(
          '{name} hat alle Daten der Familie exportiert, auch private Einträge.',
          {'name': admin.displayName},
        ),
        brief: t('Daten der Familie exportiert'),
        tag: 'package',
      ),
      null,
    );
    return _zip(file, 'famio-familie-${_today()}.zip');
  }
}
