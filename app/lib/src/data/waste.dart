import 'package:famio_client/famio_client.dart';

import 'engine_memo.dart';
import 'family_data.dart';
import 'family_extras.dart';
import '../l10n.dart';

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
      wasteSettings.pickups(occurrencesForDays(from, to));

  /// The next pickup from [now]'s day on (today's included), within
  /// [days] days.
  WastePickup? nextWastePickup(DateTime now, {int days = 2}) {
    if (!wasteConfigured) return null;
    final today = calendar.today(now);
    return wastePickups(
      today,
      DateTime(today.year, today.month, today.day + days),
    ).firstOrNull;
  }

  /// How many weeks usually lie between pickups around [day] (eight weeks
  /// back and ahead), so turns go pickup by pickup.
  int wasteTurnWeeks(DateTime day) {
    final settings = wasteSettings;
    final from = DateTime(day.year, day.month, day.day - 56);
    return EngineMemo.of(this).get(
      'wasteTurnWeeks|${settings.sourceId}|${from.toIso8601String()}',
      const {Collections.events, Collections.externalEvents},
      () => WasteSettings.turnWeeks([
        for (final p in settings.pickups(
          occurrencesForDays(from, DateTime(day.year, day.month, day.day + 57)),
        ))
          p.day,
      ]),
    );
  }

  /// Members in charge of [pickup]; empty settings mean every adult.
  /// Someone no longer in the family is skipped when taking turns.
  List<FamilyMember> wasteResponsible(WastePickup pickup) {
    final settings = wasteSettings;
    final ids = settings.responsibleFor(
      pickup.day,
      everyWeeks: settings.rotate && settings.memberIds.length > 1
          ? wasteTurnWeeks(pickup.day)
          : 1,
      members: {for (final m in members) m.id},
    );
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
    0 => tr.commonToday,
    1 => tr.commonTomorrow,
    _ => tr.wasteDaysDays(diff),
  };
  return '$when: ${pickup.label}';
}
