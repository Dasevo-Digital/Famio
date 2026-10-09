part of '../api.dart';

/// Connections of a member's lists to Bring! and Microsoft To Do.
extension _ListRoutes on FamioApi {
  ListSync get _lists =>
      lists ??
      (throw ApiException(404, 'not_found', t('Listen-Anbindungen fehlen')));

  /// Adults and children with full access connect their own accounts;
  /// guests and service accounts do not.
  FamilyMember _listMember(Request request) {
    final member = _member(request);
    if (member.isGuest) {
      throw ApiException(403, 'forbidden', t('Für Gäste nicht verfügbar'));
    }
    _checkWriter(member);
    return member;
  }

  Response _listAccounts(Request request) {
    final member = _listMember(request);
    return _json({'accounts': _lists.accounts(member.id)});
  }

  Future<Response> _listConnectBring(Request request) async {
    final member = _listMember(request);
    final body = await _body(request);
    final account = await _lists.connectBring(
      member.id,
      email: body['email'] as String? ?? '',
      password: body['password'] as String? ?? '',
    );
    _audit(member, 'hat Bring! verbunden');
    return _json(account, status: 201);
  }

  Future<Response> _listStartMicrosoft(Request request) async {
    final member = _listMember(request);
    final body = await _body(request);
    return _json(
      await _lists.startMicrosoft(
        member.id,
        clientId: body['clientId'] as String? ?? '',
      ),
    );
  }

  Future<Response> _listPollMicrosoft(Request request) async {
    final member = _listMember(request);
    final body = await _body(request);
    final result = await _lists.pollMicrosoft(
      member.id,
      body['flow'] as String? ?? '',
    );
    if (result['status'] == 'done') {
      _audit(member, 'hat Microsoft To Do verbunden');
    }
    return _json(result);
  }

  Future<Response> _listRemoteLists(Request request, String id) async {
    final member = _listMember(request);
    return _json({'lists': await _lists.remoteLists(id, member.id)});
  }

  Future<Response> _listSetLinks(Request request, String id) async {
    final member = _listMember(request);
    final body = await _body(request);
    _lists.setLinks(id, member.id, (body['links'] as List?) ?? const []);
    await _lists.syncAccount(id, report: true);
    return _json({
      'account': _lists.accounts(member.id).firstWhere((a) => a['id'] == id),
    });
  }

  Future<Response> _listSync(Request request, String id) async {
    final member = _listMember(request);
    if (!_lists.accounts(member.id).any((a) => a['id'] == id)) {
      throw ApiException(404, 'not_found', t('Verbindung nicht gefunden'));
    }
    await _lists.syncAccount(id, report: true);
    return _json({
      'account': _lists.accounts(member.id).firstWhere((a) => a['id'] == id),
    });
  }

  Response _listDisconnect(Request request, String id) {
    final member = _listMember(request);
    _lists.disconnect(id, member.id);
    _audit(member, 'hat eine Listen-Anbindung entfernt');
    return _json({'ok': true});
  }
}
