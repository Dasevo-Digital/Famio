import 'package:timezone/timezone.dart' as tz;

import '../accounts.dart';
import '../i18n.dart';
import '../push/push_service.dart';

/// iPhones with Famio installed from a Mac under a free developer account
/// stop opening it a week later, when the provisioning profile ends. The
/// apps send that end with each request; [ahead] of it the admins hear of
/// it once per device and end, to plug the phone in again in time.
class ProfileNotices {
  ProfileNotices({
    required this.accounts,
    required this.push,
    required this.location,
  });

  final Accounts accounts;
  final PushService? push;

  /// The family's time zone, for the time in the notice.
  final tz.Location Function() location;

  static const ahead = Duration(days: 2);

  /// Tells the admins about the devices whose app stops opening within
  /// [ahead]; returns the members whose devices they were (for tests).
  List<String> check() {
    final soon = accounts.expiringProfiles(DateTime.now().add(ahead));
    if (soon.isEmpty) return const [];
    final admins = {
      for (final m in accounts.members())
        if (m.isAdmin) m.id,
    };
    for (final p in soon) {
      accounts.markProfileNoticed(p.session, p.expires);
      final name = accounts.byId(p.member)?.displayName ?? '';
      // "ios (Marlys-iPhone)" as the apps name it: the phone's name.
      final device =
          RegExp(r'^\w+ \((.*)\)$').firstMatch(p.device)?[1] ?? p.device;
      push?.deliver(
        () => PushNotice(
          to: admins,
          title: t('Famio läuft bald ab'),
          body: t(
            'Auf „{device}“ von {name} öffnet sich Famio ab {when} nicht mehr. Das iPhone an den Mac anschließen und Famio neu installieren.',
            {'device': device, 'name': name, 'when': _when(p.expires)},
          ),
          brief: t('Famio läuft bald ab'),
          tag: 'hourglass',
        ),
        null,
      );
    }
    return [for (final p in soon) p.member];
  }

  String _when(DateTime at) {
    final local = tz.TZDateTime.from(at, location());
    String two(int n) => n.toString().padLeft(2, '0');
    final weekday = switch (local.weekday) {
      1 => t('Mo'),
      2 => t('Di'),
      3 => t('Mi'),
      4 => t('Do'),
      5 => t('Fr'),
      6 => t('Sa'),
      _ => t('So'),
    };
    return t('{day} {hour}:{minute} Uhr', {
      'day': t('{weekday}, {day}.{month}.', {
        'weekday': weekday,
        'day': two(local.day),
        'month': two(local.month),
      }),
      'hour': two(local.hour),
      'minute': two(local.minute),
    });
  }
}
