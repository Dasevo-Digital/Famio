import 'dart:convert';

import 'package:famio/src/design/theme.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/widgets/sync_issues_dialog.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('blocked edits are named, retained and explicitly retryable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    var blocked = true;
    final store = LocalStore.open(':memory:');
    final api = FamioApiClient(
      'http://localhost',
      httpClient: MockClient((request) async {
        final input = SyncRequest.fromJson(
          (jsonDecode(request.body) as Map).cast(),
        );
        final result = SyncResponse(
          rev: 1,
          serverTime: DateTime.now().millisecondsSinceEpoch,
          changes: blocked ? [] : input.changes,
          blocked: blocked
              ? [
                  for (final r in input.changes)
                    SyncWriteIssue(
                      collection: r.collection,
                      id: r.id,
                      updatedAt: r.updatedAt,
                      code: 'invalid_file_reference',
                    ),
                ]
              : [],
        );
        return http.Response(
          jsonEncode(result.toJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final engine = SyncEngine(store: store, api: api, memberId: 'member');
    engine.put(
      Collections.tasks,
      'task',
      Task(
        id: 'task',
        title: 'Repairable task',
        photos: const [
          FileRef(
            id: 'unavailable',
            name: 'attachment.txt',
            mime: 'text/plain',
            size: 1,
          ),
        ],
      ).toData(),
    );
    await engine.sync();
    expect(engine.status.state, SyncState.attention);
    await tester.pumpWidget(
      MaterialApp(
        theme: famioTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSyncIssues(context, engine),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text(tr.syncBlockedTitle(1)), findsOneWidget);
    expect(find.text(tr.syncBlockedFileBody), findsOneWidget);
    expect(find.text('Repairable task'), findsOneWidget);
    expect(store.get(Collections.tasks, 'task')!.dirty, isTrue);
    blocked = false;
    await tester.tap(find.text(tr.commonRetry));
    await tester.pumpAndSettle();
    expect(engine.status.state, SyncState.idle);
    expect(engine.blockedChanges, isEmpty);
    expect(
      engine.record(Collections.tasks, 'task')!.data['title'],
      'Repairable task',
    );
    expect(store.dirty, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await engine.dispose();
    store.close();
    api.close();
  });
}
