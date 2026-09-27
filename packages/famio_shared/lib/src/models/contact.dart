import '../sync_record.dart';
import 'birthday.dart';

enum ContactRole {
  pediatrician('Kinderarzt'),
  doctor('Arzt'),
  dentist('Zahnarzt'),
  midwife('Hebamme'),
  clinic('Klinik'),
  daycare('Kita'),
  school('Schule'),
  babysitter('Babysitter'),
  family('Familie & Freunde'),
  emergency('Notdienst'),
  other('Sonstige');

  const ContactRole(this.label);

  final String label;
}

/// An important contact of the family (pediatrician, daycare, babysitter
/// …), stored in `Collections.contacts`.
class FamilyContact {
  const FamilyContact({
    required this.id,
    required this.name,
    this.role = ContactRole.other,
    this.phone = '',
    this.phone2 = '',
    this.email = '',
    this.address = '',
    this.note = '',
    this.childIds = const [],
    this.birthday,
  });

  factory FamilyContact.fromRecord(SyncRecord r) => FamilyContact(
    id: r.id,
    name: r.data['name'] as String? ?? '',
    role:
        ContactRole.values.where((v) => v.name == r.data['role']).firstOrNull ??
        ContactRole.other,
    phone: r.data['phone'] as String? ?? '',
    phone2: r.data['phone2'] as String? ?? '',
    email: r.data['email'] as String? ?? '',
    address: r.data['address'] as String? ?? '',
    note: r.data['note'] as String? ?? '',
    childIds: [
      for (final c in r.data['childIds'] as List? ?? const []) c as String,
    ],
    birthday: Birthday.tryParse(r.data['birthday']),
  );

  final String id;
  final String name;
  final ContactRole role;
  final String phone;

  /// E.g. an emergency or mobile number.
  final String phone2;
  final String email;
  final String address;
  final String note;

  /// Children this contact belongs to (their doctor, daycare …).
  final List<String> childIds;

  /// Shown in the calendar and reminded of.
  final Birthday? birthday;

  Map<String, Object?> toData() => {
    'name': name,
    'role': role.name,
    'phone': phone,
    'phone2': phone2,
    'email': email,
    'address': address,
    'note': note,
    'childIds': childIds,
    'birthday': birthday?.toString(),
  };
}
