import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/push/push_service.dart';
import 'package:famio_server/src/updates/profile_notices.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  late FamioServerApp app;
  final told = <(List<String>, PushNotice)>[];

  setUp(() {
    told.clear();
    app = FamioServerApp.inMemory();
    app.push.onNotice = (ids, notice, _) => told.add((ids, notice));
  });
  tearDown(() => app.close());

  ProfileNotices notices() => ProfileNotices(
    accounts: app.accounts,
    push: app.push,
    location: () => tz.UTC,
  );

  test('admins hear once of an iPhone whose Famio stops opening', () {
    final papa = app.accounts.create(
      username: 'papa',
      displayName: 'Papa',
      isAdmin: true,
    );
    final marly = app.accounts.create(username: 'marly', displayName: 'Marly');
    final now = DateTime.now();
    final phone = app.accounts.createSession(
      marly.id,
      device: 'ios (Marlys-iPhone)',
    );
    final later = app.accounts.createSession(marly.id, device: 'ios (iPad)');
    final soon = now.add(const Duration(hours: 30));
    app.accounts
      ..noteProfileExpiry(phone, soon)
      ..noteProfileExpiry(later, now.add(const Duration(days: 6)));

    expect(notices().check(), [marly.id]);
    expect(told.single.$1, [papa.id]);
    expect(told.single.$2.title, 'Famio läuft bald ab');
    expect(told.single.$2.body, contains('„Marlys-iPhone“ von Marly'));
    expect(
      app.accounts
          .adminUsers()
          .firstWhere((u) => u.member.id == marly.id)
          .sessions
          .map((s) => s.profileExpires?.millisecondsSinceEpoch)
          .toSet(),
      {
        soon.millisecondsSinceEpoch,
        now.add(const Duration(days: 6)).millisecondsSinceEpoch,
      },
    );

    // Not again; after reinstalling, the new end is a week away.
    expect(notices().check(), isEmpty);
    app.accounts.noteProfileExpiry(
      phone,
      now.add(const Duration(days: 7, hours: 1)),
    );
    expect(notices().check(), isEmpty);
    expect(told, hasLength(1));
  });

  test('only sensible ends are taken from the header', () {
    final now = DateTime.now();
    final end = now.add(const Duration(days: 7)).toUtc();
    expect(DeviceSession.parseProfileHeader(end.toIso8601String()), end);
    expect(DeviceSession.parseProfileHeader('2001-01-01T00:00:00Z'), isNull);
    expect(DeviceSession.parseProfileHeader('morgen'), isNull);
    expect(DeviceSession.parseProfileHeader(null), isNull);
  });
}
