import 'models/birthday.dart';

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

  const MemberRole(this.label);

  final String label;

  static MemberRole parse(Object? name) =>
      values.where((r) => r.name == name).firstOrNull ?? adult;
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
  });

  factory FamilyMember.fromJson(Map<String, Object?> json) => FamilyMember(
    id: json['id'] as String,
    username: json['username'] as String,
    displayName: json['displayName'] as String,
    isAdmin: json['isAdmin'] as bool? ?? false,
    color: json['color'] as int?,
    birthday: Birthday.tryParse(json['birthday']),
    role: MemberRole.parse(json['role']),
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
  };
}
