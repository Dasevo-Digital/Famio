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
