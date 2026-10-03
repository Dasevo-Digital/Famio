/// A member's connection to lists in another app (Bring!, Microsoft To Do).
class ListAccount {
  const ListAccount({
    required this.id,
    required this.provider,
    required this.name,
    this.lastSync,
    this.lastError,
    this.links = const [],
  });

  factory ListAccount.fromJson(Map<String, Object?> json) => ListAccount(
    id: json['id'] as String,
    provider: json['provider'] as String? ?? '',
    name: json['name'] as String? ?? '',
    lastSync: switch (json['lastSync']) {
      final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      _ => null,
    },
    lastError: json['lastError'] as String?,
    links: [
      for (final l in (json['links'] as List?) ?? const [])
        ListLink.fromJson((l as Map).cast()),
    ],
  );

  final String id;

  /// [bring] or [microsoft].
  final String provider;
  final String name;
  final DateTime? lastSync;

  /// Why the last sync failed; null if it worked.
  final String? lastError;
  final List<ListLink> links;

  static const bring = 'bring';
  static const microsoft = 'mstodo';

  /// The Famio list of [links] for tasks.
  static const tasksList = 'tasks';

  bool get isBring => provider == bring;
}

/// A Famio list (tasks or a shopping list id) and the list it goes with.
class ListLink {
  const ListLink({
    required this.famioList,
    required this.remoteList,
    this.remoteName = '',
  });

  factory ListLink.fromJson(Map<String, Object?> json) => ListLink(
    famioList: json['famioList'] as String,
    remoteList: json['remoteList'] as String,
    remoteName: json['remoteName'] as String? ?? '',
  );

  final String famioList;
  final String remoteList;
  final String remoteName;

  Map<String, Object?> toJson() => {
    'famioList': famioList,
    'remoteList': remoteList,
    'remoteName': remoteName,
  };
}

/// A list in the other app the member can pick.
class RemoteListInfo {
  const RemoteListInfo({required this.id, required this.name});

  factory RemoteListInfo.fromJson(Map<String, Object?> json) =>
      RemoteListInfo(id: json['id'] as String, name: json['name'] as String);

  final String id;
  final String name;
}

/// What the member does to sign in to Microsoft: open [verificationUri] and
/// enter [userCode].
class DeviceLogin {
  const DeviceLogin({
    required this.flow,
    required this.userCode,
    required this.verificationUri,
    this.interval = 5,
  });

  factory DeviceLogin.fromJson(Map<String, Object?> json) => DeviceLogin(
    flow: json['flow'] as String,
    userCode: json['userCode'] as String,
    verificationUri: json['verificationUri'] as String,
    interval: (json['interval'] as num?)?.toInt() ?? 5,
  );

  final String flow;
  final String userCode;
  final String verificationUri;

  /// Seconds between two questions whether the member is done.
  final int interval;
}
