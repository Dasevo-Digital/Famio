import 'package:famio/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('English backup counts use singular only for one', () {
    final en = lookupL10n(const Locale('en'));
    expect(en.adminCountVersionsSizeMb(1, '1'), startsWith('1 version ·'));
    expect(en.adminCountVersionsSizeMb(0, '0'), startsWith('0 versions ·'));
    expect(en.adminCountVersionsSizeMb(2, '1'), startsWith('2 versions ·'));
    expect(
      en.adminCheckedAgoCanRestored('', 1, 1, 1, ''),
      endsWith('(1 entry, 1 member, 1 file)'),
    );
    expect(
      en.adminCheckedAgoCanRestored('', 0, 2, 0, ''),
      endsWith('(0 entries, 2 members, 0 files)'),
    );
  });
}
