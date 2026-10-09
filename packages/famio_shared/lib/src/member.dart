import 'models/birthday.dart';
import 'texts.dart';

/// What a member may do besides the data's own visibility rules.
enum MemberRole {
  /// Full member (parents, older children).
  adult('Erwachsen'),

  /// Earns points and pocket money; chores, rewards and allowances are
  /// managed by adults, and their completed chores need an adult's okay.
  child('Kind'),

  /// Grandparents, babysitters …: calendar, chat, shopping and tasks only –
  /// no documents, health data, finances or locations.
  guest('Gast'),

  /// Technical access, e.g. the Home Assistant integration: sees what an
  /// adult sees, but is no family member – hidden from chats, pickers and
  /// member lists, never an administrator.
  service('Dienstkonto');

  const MemberRole(this._label);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('MemberRole.$name', _label);

  static MemberRole parse(Object? name) =>
      values.where((r) => r.name == name).firstOrNull ?? adult;
}

/// What a service account may change (see [MemberRole.service]).
enum ServiceAccess {
  full('Lesen und ändern'),

  /// Tick off tasks, chores and routines, keep the shopping lists – e.g. a
  /// wall display or voice assistant. Nothing else.
  everyday('Abhaken und Einkauf'),

  readOnly('Nur lesen');

  const ServiceAccess(this._label);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('ServiceAccess.$name', _label);

  static ServiceAccess parse(Object? name) =>
      values.where((a) => a.name == name).firstOrNull ?? full;
}

/// A family member (user account on the server).
class FamilyMember {
  const FamilyMember({
    required this.id,
    required this.username,
    required this.displayName,
    this.isAdmin = false,
    this.color,
    this.birthday,
    this.role = MemberRole.adult,
    this.serviceAccess = ServiceAccess.full,
  });

  factory FamilyMember.fromJson(Map<String, Object?> json) => FamilyMember(
    id: json['id'] as String,
    username: json['username'] as String,
    displayName: json['displayName'] as String,
    isAdmin: json['isAdmin'] as bool? ?? false,
    color: json['color'] as int?,
    birthday: Birthday.tryParse(json['birthday']),
    role: MemberRole.parse(json['role']),
    serviceAccess: ServiceAccess.parse(json['serviceAccess']),
  );

  final String id;
  final String username;
  final String displayName;
  final bool isAdmin;

  /// ARGB color used for avatars and calendar entries.
  final int? color;

  /// Shown in the calendar and reminded of.
  final Birthday? birthday;

  final MemberRole role;

  /// Only meaningful for service accounts.
  final ServiceAccess serviceAccess;

  /// A service account that may not change everything.
  bool get isLimited => isService && serviceAccess != ServiceAccess.full;

  bool get isGuest => role == MemberRole.guest;
  bool get isChild => role == MemberRole.child;
  bool get isService => role == MemberRole.service;

  /// Adults manage chores, rewards and pocket money.
  bool get isAdult => role == MemberRole.adult;

  Map<String, Object?> toJson() => {
    'id': id,
    'username': username,
    'displayName': displayName,
    'isAdmin': isAdmin,
    'color': color,
    'birthday': ?birthday?.toString(),
    'role': role.name,
    if (isService) 'serviceAccess': serviceAccess.name,
  };
}
