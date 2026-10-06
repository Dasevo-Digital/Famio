import 'package:famio_shared/famio_shared.dart';

import '../accounts.dart';
import '../api_exception.dart';
import '../push/push_service.dart';
import '../record_store.dart';

/// The emergency button: a member raises an alert with their position, the
/// adults get an alarm that breaks through quiet times, one answers "Ich
/// komme", and the phone keeps sending its position for
/// [SosAlert.live].
class SosService {
  SosService({required this.records, required this.accounts, this.push});

  final RecordStore records;
  final Accounts accounts;
  final PushService? push;

  /// A second press within this time updates the open alert instead of
  /// raising a new one.
  static const _repeat = Duration(minutes: 30);

  List<FamilyMember> _adults(String except) => [
    for (final m in accounts.members())
      if (m.isAdult && m.id != except) m,
  ];

  SosAlert? _get(String id) {
    final r = records.get(Collections.sosAlerts, id);
    return r == null || r.deleted ? null : SosAlert.fromRecord(r);
  }

  SyncRecord _write(SosAlert alert, List<String> visibleTo) {
    final record = SyncRecord(
      collection: Collections.sosAlerts,
      id: alert.id,
      data: {...alert.toData(), SyncRecord.visibilityKey: visibleTo},
      updatedAt: 0,
    );
    records.writeAsServer([record]);
    return records.get(Collections.sosAlerts, alert.id)!;
  }

  List<String> _audience(SosAlert alert) => [
    alert.memberId,
    for (final a in _adults(alert.memberId)) a.id,
  ];

  /// [member] pressed the button.
  SosAlert raise(
    FamilyMember member, {
    double? latitude,
    double? longitude,
    double? accuracy,
    int? battery,
  }) {
    if (member.isGuest || member.isService) {
      throw ApiException(403, 'forbidden', 'Für dieses Konto nicht verfügbar');
    }
    final now = DateTime.now();
    final open =
        [
          for (final r in records.all(Collections.sosAlerts))
            SosAlert.fromRecord(r),
        ].where(
          (a) =>
              a.memberId == member.id &&
              a.open &&
              now.difference(a.startedAt) < _repeat,
        );
    final previous = open.isEmpty ? null : open.first;
    final position = latitude != null && longitude != null;
    final alert = SosAlert(
      id: previous?.id ?? newId(),
      memberId: member.id,
      startedAt: previous?.startedAt ?? now,
      state: previous?.state ?? SosState.active,
      latitude: position ? latitude : previous?.latitude,
      longitude: position ? longitude : previous?.longitude,
      accuracy: position ? accuracy : previous?.accuracy,
      positionAt: position ? now : previous?.positionAt,
      battery: battery ?? previous?.battery,
      comingBy: previous?.comingBy,
      liveUntil: now.add(SosAlert.live),
    );
    final record = _write(alert, _audience(alert));
    final adults = _adults(member.id);
    _notify(
      record,
      to: {for (final a in adults) a.id},
      title: '🚨 SOS von ${member.displayName}',
      body: position
          ? '${member.displayName} braucht Hilfe. Standort in Famio ansehen.'
          : '${member.displayName} braucht Hilfe. Der Standort ist noch '
                'unbekannt.',
    );
    return alert;
  }

  /// A newer position from the phone that raised [id].
  SosAlert position(
    FamilyMember member,
    String id, {
    required double latitude,
    required double longitude,
    double? accuracy,
    int? battery,
  }) {
    final alert = _get(id);
    if (alert == null || alert.memberId != member.id) {
      throw ApiException(404, 'not_found', 'Notfall nicht gefunden');
    }
    final now = DateTime.now();
    if (!alert.open ||
        (alert.liveUntil != null && now.isAfter(alert.liveUntil!))) {
      throw ApiException(409, 'sos_closed', 'Der Notfall ist beendet');
    }
    final updated = SosAlert(
      id: alert.id,
      memberId: alert.memberId,
      startedAt: alert.startedAt,
      state: alert.state,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      positionAt: now,
      battery: battery ?? alert.battery,
      comingBy: alert.comingBy,
      liveUntil: alert.liveUntil,
    );
    _write(updated, _audience(updated));
    return updated;
  }

  /// An adult is on the way.
  SosAlert coming(FamilyMember adult, String id) {
    if (!adult.isAdult) {
      throw ApiException(403, 'forbidden', 'Nur Erwachsene');
    }
    final alert = _get(id);
    if (alert == null) {
      throw ApiException(404, 'not_found', 'Notfall nicht gefunden');
    }
    if (!alert.open) return alert;
    final updated = SosAlert(
      id: alert.id,
      memberId: alert.memberId,
      startedAt: alert.startedAt,
      state: SosState.coming,
      latitude: alert.latitude,
      longitude: alert.longitude,
      accuracy: alert.accuracy,
      positionAt: alert.positionAt,
      battery: alert.battery,
      comingBy: adult.id,
      liveUntil: alert.liveUntil,
    );
    final record = _write(updated, _audience(updated));
    _notify(
      record,
      to: {alert.memberId, for (final a in _adults(adult.id)) a.id},
      title: '${adult.displayName} kommt',
      body: '${adult.displayName} hat den Notfall gesehen und ist unterwegs.',
    );
    return updated;
  }

  /// Over: by an adult or the member who raised it.
  SosAlert resolve(FamilyMember member, String id) {
    final alert = _get(id);
    if (alert == null || (!member.isAdult && alert.memberId != member.id)) {
      throw ApiException(404, 'not_found', 'Notfall nicht gefunden');
    }
    if (!alert.open) return alert;
    final now = DateTime.now();
    final updated = SosAlert(
      id: alert.id,
      memberId: alert.memberId,
      startedAt: alert.startedAt,
      state: SosState.resolved,
      latitude: alert.latitude,
      longitude: alert.longitude,
      accuracy: alert.accuracy,
      positionAt: alert.positionAt,
      battery: alert.battery,
      comingBy: alert.comingBy,
      resolvedBy: member.id,
      resolvedAt: now,
      liveUntil: now,
    );
    final record = _write(updated, _audience(updated));
    final who = accounts.members().where((m) => m.id == alert.memberId);
    final name = who.isEmpty ? 'Jemand' : who.first.displayName;
    push?.deliver(
      PushNotice(
        to: {
          for (final id in _audience(updated))
            if (id != member.id) id,
        },
        title: 'Notfall beendet',
        body: 'Der Notfall von $name ist beendet (${member.displayName}).',
        brief: 'Notfall beendet',
        tag: 'white_check_mark',
      ),
      record,
    );
    return updated;
  }

  final _rung = <String, DateTime>{};

  /// Lets [memberId]'s phone ring loudly (also on silent, where the phone
  /// allows it), e.g. when they do not answer. At most once a minute.
  void ring(FamilyMember adult, String memberId) {
    if (!adult.isAdult) {
      throw ApiException(403, 'forbidden', 'Nur Erwachsene');
    }
    final target = accounts.members().where((m) => m.id == memberId);
    if (target.isEmpty || memberId == adult.id || target.first.isService) {
      throw ApiException(404, 'not_found', 'Mitglied nicht gefunden');
    }
    final last = _rung[memberId];
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      throw ApiException(
        429,
        'too_soon',
        'Gerade erst geklingelt – bitte eine Minute warten.',
      );
    }
    _rung[memberId] = now;
    push?.deliver(
      PushNotice(
        to: {memberId},
        title: '🔔 ${adult.displayName} sucht dich',
        body: 'Bitte melde dich bei ${adult.displayName}.',
        brief: '🔔 ${adult.displayName} sucht dich',
        tag: ringTag,
        urgent: true,
      ),
      null,
    );
  }

  /// ntfy tag of a ring; the apps sound the siren for it.
  static const ringTag = 'loud_sound';

  void _notify(
    SyncRecord about, {
    required Set<String> to,
    required String title,
    required String body,
  }) => push?.deliver(
    PushNotice(
      to: to,
      title: title,
      body: body,
      // Also without details: an emergency must be recognisable.
      brief: title,
      tag: 'rotating_light',
      urgent: true,
    ),
    about,
  );
}
