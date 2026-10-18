import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/push/push_service.dart';
import 'package:famio_server/src/updates/update_notices.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  final told = <(List<String>, PushNotice)>[];

  setUp(() {
    told.clear();
    app = FamioServerApp.inMemory();
    app.push.onNotice = (ids, notice, _) => told.add((ids, notice));
  });
  tearDown(() => app.close());

  String member(String name, List<String> apps) {
    final m = app.accounts.create(username: name, displayName: name);
    for (final v in apps) {
      app.accounts.noteAppVersion(app.accounts.createSession(m.id), v);
    }
    return m.id;
  }

  UpdateNotices notices() => UpdateNotices(
    db: app.db,
    accounts: app.accounts,
    push: app.push,
    version: '2.1.0',
  );

  test('members with an older updatable app hear of it once', () {
    final mama = member('mama', ['2.0.7 android', '2.1.0 macos']);
    final papa = member('papa', ['2.1.0 android']);
    final kind = member('kind', ['2.0.7 ios']);
    final oma = member('oma', ['2.0.5 windows']);

    final first = notices().announce({
      AppPlatform.android,
      AppPlatform.androidArm64,
      AppPlatform.linux,
    });
    // Papa is current, the iPhone and Windows have no package here.
    expect(first, {mama});
    expect(told.single.$1, [mama]);
    expect(told.single.$2.title, 'Famio 2.1.0 ist da');

    // A restart does not repeat it; a new package type reaches the rest.
    expect(notices().announce({AppPlatform.android}), isEmpty);
    expect(notices().announce({AppPlatform.windows}), {oma});
    expect([papa, kind], everyElement(isNot(isIn(told.expand((t) => t.$1)))));
  });
}
