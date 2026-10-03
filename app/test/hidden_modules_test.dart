import 'package:famio/src/design/palette.dart';
import 'package:famio/src/screens/home_shell.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('switched-off areas leave the navigation', () {
    final all = sectionsFor(MemberRole.adult);
    expect(all, contains(FamioSection.budget));
    final some = sectionsFor(MemberRole.adult, hidden: {'budget', 'meals'});
    expect(some, isNot(contains(FamioSection.budget)));
    expect(some, isNot(contains(FamioSection.meals)));
    expect(some, containsAll([FamioSection.home, FamioSection.settings]));
    expect(some.length, all.length - 2);
  });

  test('guests keep their own limits on top', () {
    final guest = sectionsFor(MemberRole.guest, hidden: {'chat'});
    expect(guest, isNot(contains(FamioSection.chat)));
    expect(guest, isNot(contains(FamioSection.budget)));
    expect(guest, contains(FamioSection.shopping));
  });

  test('every area that can be hidden is a section of the app', () {
    for (final name in ServerSettings.optionalModules) {
      // The list connections are a feature, not a section.
      if (name == ServerSettings.listSyncModule) continue;
      expect(FamioSection.values.map((s) => s.name), contains(name));
    }
  });
}
