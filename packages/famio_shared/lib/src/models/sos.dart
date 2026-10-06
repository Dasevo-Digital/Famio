import '../member.dart';
import '../sync_record.dart';

/// How the family's emergency button behaves; one record
/// ([SosSettings.recordId]) in `sos_settings`, changed by adults only.
class SosSettings {
  const SosSettings({
    this.siren = true,
    this.sms = true,
    this.phones = const {},
    this.call = const {},
  });

  factory SosSettings.fromRecord(SyncRecord? r) {
    final d = r?.data ?? const {};
    Map<String, String> strings(Object? v) => {
      if (v is Map)
        for (final e in v.entries)
          if (e.value is String && (e.value as String).trim().isNotEmpty)
            '${e.key}': (e.value as String).trim(),
    };
    return SosSettings(
      siren: d['siren'] as bool? ?? true,
      sms: d['sms'] as bool? ?? true,
      phones: strings(d['phones']),
      call: strings(d['call']),
    );
  }

  static const recordId = 'family';

  /// [call] value: dial the emergency number instead of a member.
  static const emergency = 'emergency';

  /// [call] value: no call at all.
  static const none = 'none';

  /// The number dialled for [emergency].
  static const emergencyNumber = '112';

  /// The phone sounds a loud siren (also on silent).
  final bool siren;

  /// Without internet, the phone sends a text with its position.
  final bool sms;

  /// Phone numbers of members (member id → number), for calls and texts.
  final Map<String, String> phones;

  /// Whom a member's button calls (member id → member id, [emergency] or
  /// [none]); without an entry the first adult with a number.
  final Map<String, String> call;

  /// The member a call from [memberId] goes to: their setting, else the
  /// first adult (in [adults] order) with a phone number. Null for
  /// [emergency] and [none].
  String? callMember(String memberId, List<FamilyMember> adults) {
    final chosen = call[memberId];
    if (chosen == emergency || chosen == none) return null;
    if (chosen != null && phones.containsKey(chosen)) return chosen;
    for (final a in adults) {
      if (a.id != memberId && phones.containsKey(a.id)) return a.id;
    }
    return null;
  }

  /// The number [memberId]'s button dials, or null for no call.
  String? callNumber(String memberId, List<FamilyMember> adults) {
    if (call[memberId] == emergency) return emergencyNumber;
    final m = callMember(memberId, adults);
    return m == null ? null : phones[m];
  }

  /// Numbers that get a text when the phone is offline: the called member
  /// first, then the other adults with a number.
  List<String> smsNumbers(String memberId, List<FamilyMember> adults) {
    final first = callMember(memberId, adults);
    return {
      if (first != null) phones[first]!,
      for (final a in adults)
        if (a.id != memberId && phones[a.id] != null) phones[a.id]!,
    }.toList();
  }

  SosSettings copyWith({
    bool? siren,
    bool? sms,
    Map<String, String>? phones,
    Map<String, String>? call,
  }) => SosSettings(
    siren: siren ?? this.siren,
    sms: sms ?? this.sms,
    phones: phones ?? this.phones,
    call: call ?? this.call,
  );

  Map<String, Object?> toData() => {
    'siren': siren,
    'sms': sms,
    'phones': phones,
    'call': call,
  };
}

enum SosState {
  /// Raised, nobody answered yet.
  active,

  /// An adult is on the way.
  coming,
  resolved,
}

/// An emergency raised with the button; written by the server, seen by the
/// member who raised it and the adults.
class SosAlert {
  const SosAlert({
    required this.id,
    required this.memberId,
    required this.startedAt,
    this.state = SosState.active,
    this.latitude,
    this.longitude,
    this.accuracy,
    this.positionAt,
    this.battery,
    this.comingBy,
    this.resolvedBy,
    this.resolvedAt,
    this.liveUntil,
  });

  factory SosAlert.fromRecord(SyncRecord r) {
    final d = r.data;
    return SosAlert(
      id: r.id,
      memberId: d['memberId'] as String? ?? '',
      startedAt:
          _time(d['startedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      state: SosState.values.firstWhere(
        (s) => s.name == d['state'],
        orElse: () => SosState.active,
      ),
      latitude: (d['latitude'] as num?)?.toDouble(),
      longitude: (d['longitude'] as num?)?.toDouble(),
      accuracy: (d['accuracy'] as num?)?.toDouble(),
      positionAt: _time(d['positionAt']),
      battery: (d['battery'] as num?)?.toInt(),
      comingBy: d['comingBy'] as String?,
      resolvedBy: d['resolvedBy'] as String?,
      resolvedAt: _time(d['resolvedAt']),
      liveUntil: _time(d['liveUntil']),
    );
  }

  /// How long the phone keeps sending its position.
  static const live = Duration(minutes: 30);

  final String id;
  final String memberId;
  final DateTime startedAt;
  final SosState state;
  final double? latitude;
  final double? longitude;

  /// Metres.
  final double? accuracy;
  final DateTime? positionAt;
  final int? battery;

  /// The adult on the way.
  final String? comingBy;
  final String? resolvedBy;
  final DateTime? resolvedAt;
  final DateTime? liveUntil;

  bool get open => state != SosState.resolved;
  bool get hasPosition => latitude != null && longitude != null;

  /// A link that opens the position in any map (also in a text message).
  String? get mapLink => hasPosition
      ? 'https://www.openstreetmap.org/?mlat=${latitude!.toStringAsFixed(6)}'
            '&mlon=${longitude!.toStringAsFixed(6)}#map=17/'
            '${latitude!.toStringAsFixed(6)}/${longitude!.toStringAsFixed(6)}'
      : null;

  Map<String, Object?> toData() => {
    'memberId': memberId,
    'startedAt': _iso(startedAt),
    'state': state.name,
    'latitude': ?latitude,
    'longitude': ?longitude,
    'accuracy': ?accuracy,
    'positionAt': ?_iso(positionAt),
    'battery': ?battery,
    'comingBy': ?comingBy,
    'resolvedBy': ?resolvedBy,
    'resolvedAt': ?_iso(resolvedAt),
    'liveUntil': ?_iso(liveUntil),
  };
}

DateTime? _time(Object? v) =>
    v is String ? DateTime.tryParse(v)?.toLocal() : null;

String? _iso(DateTime? t) => t?.toUtc().toIso8601String();
