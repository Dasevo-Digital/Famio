// A section that is not shown (the start page behind the open chat) does
// not rebuild on every change, only once it is shown again.
import 'package:famio/src/app_state.dart';
import 'package:famio/src/widgets/data_builder.dart';
import 'package:famio/src/widgets/section_shown.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('a hidden section rebuilds once it is shown', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    state.engine = engine;
    var builds = 0;
    Widget app(bool shown) => AppScope(
      state: state,
      child: SectionShown(
        shown: shown,
        child: DataBuilder(
          collections: const {Collections.notes},
          builder: (context, engine) {
            builds++;
            return Text(
              '${engine.records(Collections.notes).length}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ),
    );
    await tester.pumpWidget(app(true));
    expect(builds, 1);
    // The change arrives in one frame, the rebuild comes with the next.
    Future<void> frames() async {
      await tester.pump();
      await tester.pump();
    }

    engine.put(Collections.notes, 'n1', {'title': 'Eins'});
    await frames();
    expect(builds, 2);

    await tester.pumpWidget(app(false));
    final hidden = builds;
    for (var i = 2; i < 5; i++) {
      engine.put(Collections.notes, 'n$i', {'title': 'Noch eine'});
      await frames();
    }
    expect(builds, hidden);

    await tester.pumpWidget(app(true));
    expect(builds, hidden + 1);
    expect(find.text('4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await engine.dispose();
  });
}
