import 'package:famio_client/famio_client.dart';

import 'family_data.dart';
import 'family_extras.dart';

/// The bins: pickup days from the municipality's calendar and whose turn
/// it is to put them out.
extension WasteData on SyncEngine {
  WasteSettings get wasteSettings {
    final r = record(Collections.wasteSettings, WasteSettings.recordId);
    return r == null ? const WasteSettings() : WasteSettings.fromRecord(r);
  }

  /// Whether the family set the bins up; until then Famio stays quiet.
  bool get wasteConfigured =>
      record(Collections.wasteSettings, WasteSettings.recordId) != null;

  void saveWasteSettings(WasteSettings s) =>
      put(Collections.wasteSettings, WasteSettings.recordId, s.toData());

  /// Pickup days within `[from, to)`.
  List<WastePickup> wastePickups(DateTime from, DateTime to) =>
      wasteSettings.pickups(occurrences(from, to));

  /// The next pickup from [now]'s day on (today's included), within
  /// [days] days.
  WastePickup? nextWastePickup(DateTime now, {int days = 2}) {
    if (!wasteConfigured) return null;
    final today = DateTime(now.year, now.month, now.day);
    return wastePickups(
      today,
      DateTime(today.year, today.month, today.day + days),
    ).firstOrNull;
  }

  /// Members in charge of [pickup]; empty settings mean every adult.
  List<FamilyMember> wasteResponsible(WastePickup pickup) {
    final ids = wasteSettings.responsibleFor(pickup.day);
    if (ids.isEmpty) {
      return [
        for (final m in members)
          if (m.isAdult) m,
      ];
    }
    return [for (final id in ids) ?member(id)];
  }

  bool wasteIsMine(WastePickup pickup) =>
      wasteResponsible(pickup).any((m) => m.id == memberId) ||
      (wasteSettings.memberIds.isEmpty && iAmAdult);
}

/// "Morgen: 🟡 Gelbe Tonne" / "Heute: …".
String wasteHeadline(WastePickup pickup, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final diff = DateTime.utc(
    pickup.day.year,
    pickup.day.month,
    pickup.day.day,
  ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  final when = switch (diff) {
    0 => 'Heute',
    1 => 'Morgen',
    _ => 'In $diff Tagen',
  };
  return '$when: ${pickup.label}';
}
