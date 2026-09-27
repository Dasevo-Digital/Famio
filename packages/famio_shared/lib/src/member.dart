import 'models/birthday.dart';

/// A family member (user account on the server).
class FamilyMember {
  const FamilyMember({
    required this.id,
    required this.username,
    required this.displayName,
    this.isAdmin = false,
    this.color,
    this.birthday,
  });

  factory FamilyMember.fromJson(Map<String, Object?> json) => FamilyMember(
    id: json['id'] as String,
    username: json['username'] as String,
    displayName: json['displayName'] as String,
    isAdmin: json['isAdmin'] as bool? ?? false,
    color: json['color'] as int?,
    birthday: Birthday.tryParse(json['birthday']),
  );

  final String id;
  final String username;
  final String displayName;
  final bool isAdmin;

  /// ARGB color used for avatars and calendar entries.
  final int? color;

  /// Shown in the calendar and reminded of.
  final Birthday? birthday;

  Map<String, Object?> toJson() => {
    'id': id,
    'username': username,
    'displayName': displayName,
    'isAdmin': isAdmin,
    'color': color,
    'birthday': ?birthday?.toString(),
  };
}
