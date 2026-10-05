/// A device receiving push notifications through ntfy (or a compatible
/// server), see `/api/me/push`.
class PushTarget {
  const PushTarget({
    required this.id,
    required this.name,
    required this.url,
    this.details = false,
    this.hasToken = false,
    this.lastError,
  });

  factory PushTarget.fromJson(Map<String, Object?> json) => PushTarget(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
    details: json['details'] as bool? ?? false,
    hasToken: json['hasToken'] as bool? ?? false,
    lastError: json['lastError'] as String?,
  );

  final String id;
  final String name;

  /// Topic URL, e.g. `https://ntfy.sh/famio-k3j…` – the secret topic name
  /// is what protects it on public servers.
  final String url;

  /// Include names and texts; otherwise only "Neue Nachricht" etc., so the
  /// push server never learns family details.
  final bool details;
  final bool hasToken;
  final String? lastError;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'details': details,
    'hasToken': hasToken,
    'lastError': lastError,
  };
}

/// When a member wants no sound from Famio's notifications (e.g. at night),
/// see `/api/me/quiet-hours`. Notifications still arrive, just silently.
/// Reminders the member set themselves (appointments, medications) stay
/// loud; arrival notices stay loud if [placesLoud].
class QuietHours {
  const QuietHours({
    this.enabled = false,
    this.start = 21 * 60,
    this.end = 7 * 60,
    this.placesLoud = true,
  });

  factory QuietHours.fromJson(Map<String, Object?> json) => QuietHours(
    enabled: json['enabled'] as bool? ?? false,
    start: _minutes(json['start']) ?? 21 * 60,
    end: _minutes(json['end']) ?? 7 * 60,
    placesLoud: json['placesLoud'] as bool? ?? true,
  );

  final bool enabled;

  /// Minutes after midnight in the family's time zone; [end] may be before
  /// [start] (over midnight).
  final int start;
  final int end;

  /// Arrival and leaving notices of places stay loud.
  final bool placesLoud;

  /// Whether [localTime] (family time) falls into the quiet time.
  bool isQuietAt(DateTime localTime) {
    if (!enabled || start == end) return false;
    final m = localTime.hour * 60 + localTime.minute;
    return start < end ? m >= start && m < end : m >= start || m < end;
  }

  /// "21:00".
  static String format(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';

  static int? _minutes(Object? value) {
    if (value is int) return value.clamp(0, 24 * 60 - 1);
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch('$value');
    if (match == null) return null;
    final h = int.parse(match[1]!);
    final m = int.parse(match[2]!);
    if (h > 23 || m > 59) return null;
    return h * 60 + m;
  }

  QuietHours copyWith({
    bool? enabled,
    int? start,
    int? end,
    bool? placesLoud,
  }) => QuietHours(
    enabled: enabled ?? this.enabled,
    start: start ?? this.start,
    end: end ?? this.end,
    placesLoud: placesLoud ?? this.placesLoud,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'start': format(start),
    'end': format(end),
    'placesLoud': placesLoud,
  };
}
