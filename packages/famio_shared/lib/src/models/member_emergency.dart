import '../sync_record.dart';
import 'kids.dart';

/// What helpers need about an adult in an emergency: the same facts as for
/// children ([EmergencyInfo]), plus whom to call and where the powers of
/// attorney and the living will are kept. One record per member
/// (`Collections.memberEmergency`, id = member id), written only by that
/// member and received only by the family's adults.
class MemberEmergency {
  const MemberEmergency({
    required this.memberId,
    this.info = const EmergencyInfo(),
    this.contactId,
    this.documents = '',
  });

  factory MemberEmergency.fromRecord(SyncRecord r) => MemberEmergency(
    memberId: r.id,
    info: EmergencyInfo.fromJson(r.data['info']),
    contactId: r.data['contactId'] as String?,
    documents: r.data['documents'] as String? ?? '',
  );

  final String memberId;

  /// Allergies, illnesses, medicines, blood group, insurance, family
  /// doctor (`doctorContactId`) and notes.
  final EmergencyInfo info;

  /// Whom to call, in `Collections.contacts`.
  final String? contactId;

  /// Where the power of attorney, the living will or the organ donor card
  /// are kept.
  final String documents;

  bool get isEmpty => info.isEmpty && contactId == null && documents.isEmpty;

  Map<String, Object?> toData() => {
    'info': info.toJson(),
    'contactId': ?contactId,
    if (documents.isNotEmpty) 'documents': documents,
  };
}
