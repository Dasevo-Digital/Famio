import 'dart:async';

import 'package:famio_shared/famio_shared.dart';
import 'package:timezone/timezone.dart' as tz;

import '../accounts.dart';
import '../record_store.dart';

/// Books the weekly pocket money on each payday, also for days the server
/// was off (up to [catchUp] back). Ids are fixed per payday, so a booking an
/// adult deleted stays deleted.
class AllowanceJob {
  AllowanceJob({
    required this.records,
    required this.accounts,
    required this.location,
    this.onChanged,
  });

  final RecordStore records;
  final Accounts accounts;
  final tz.Location Function() location;
  final void Function()? onChanged;

  static const catchUp = Duration(days: 56);

  Timer? _timer;

  void start() {
    run();
    _timer = Timer.periodic(const Duration(hours: 1), (_) => run());
  }

  void stop() => _timer?.cancel();

  /// Returns how many bookings were made.
  int run({DateTime? now}) {
    final today = now ?? tz.TZDateTime.now(location());
    final day = DateTime(today.year, today.month, today.day);
    final members = {for (final m in accounts.members()) m.id};
    final bookings = <SyncRecord>[];
    for (final r in records.all(Collections.allowances)) {
      final allowance = Allowance.fromRecord(r);
      if (allowance.weeklyCents <= 0 || !members.contains(allowance.memberId)) {
        continue;
      }
      for (final payday in allowance.paydays(day.subtract(catchUp), day)) {
        final id = allowance.bookingId(payday);
        if (records.get(Collections.moneyEntries, id) != null) continue;
        final entry = MoneyEntry(
          id: id,
          memberId: allowance.memberId,
          cents: allowance.weeklyCents,
          at: tz.TZDateTime(
            location(),
            payday.year,
            payday.month,
            payday.day,
            8,
          ),
          kind: MoneyKind.allowance,
          note: 'Taschengeld',
        );
        bookings.add(
          SyncRecord(
            collection: Collections.moneyEntries,
            id: id,
            data: entry.toData(),
            updatedAt: 0,
          ),
        );
      }
    }
    if (bookings.isEmpty) return 0;
    records.writeAsServer(bookings);
    onChanged?.call();
    return bookings.length;
  }
}
