part of '../api.dart';

extension _TrashRoutes on FamioApi {
  Response _trashList(Request request) {
    final member = _auth(request);
    final raw = request.url.queryParameters['before'];
    final before = raw == null ? null : int.tryParse(raw);
    if (raw != null && (before == null || before < 1)) {
      throw ApiException.badRequest('invalid_cursor', t('Ungültige Anfrage'));
    }
    final (items, next) = records.trashFor(member.id, before: before);
    return _json({
      'items': [
        for (final item in items)
          {
            ...item.toJson(),
            'canRestore': records.mayRestoreTrash(member.id, item),
          },
      ],
      'next': next,
    });
  }

  Response _trashRestore(Request request, String id) {
    final member = _auth(request);
    records.restoreTrash(member.id, id);
    hub.notifyRev(records.currentRev);
    onEventsChanged?.call();
    lists?.poke();
    return _json({'ok': true});
  }
}
