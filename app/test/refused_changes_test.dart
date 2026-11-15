import 'dart:convert';

import 'package:famio/src/widgets/refused_changes.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An edit the server turns down disappears from the device; the app says
/// so once (#539).
void main() {
  Future<SyncEngine> pumpNotice(
    WidgetTester tester, {
    required bool refuse,
  }) async {
    final api = FamioApiClient(
      'localhost:1',
      httpClient: MockClient((request) async {
        final sent = SyncRequest.fromJson(
          (jsonDecode(request.body) as Map).cast(),
        );
        final response = SyncResponse(
          rev: 1,
          serverTime: DateTime.now().millisecondsSinceEpoch,
          rejected: [
            for (final c in sent.changes)
              SyncRecord(
                collection: c.collection,
                id: c.id,
                data: const {},
                deleted: true,
                updatedAt: 1,
                updatedBy: 'server',
              ),
          ],
          // An older server sends no reason.
          refused: [
            if (refuse)
              for (final c in sent.changes)
                SyncWriteIssue(
                  collection: c.collection,
                  id: c.id,
                  updatedAt: c.updatedAt,
                  code: 'not_allowed',
                ),
          ],
        );
        return http.Response(
          jsonEncode(response.toJson()),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final store = LocalStore.open(':memory:');
    final engine = SyncEngine(store: store, api: api, memberId: 'kid');
    addTearDown(() async {
      await engine.dispose();
      store.close();
      api.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RefusedChangesNotice(
            engine: engine,
            child: const Text('Famio'),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      engine.delete(Collections.calendarSubscriptions, 'ferien');
      await engine.sync();
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    return engine;
  }

  testWidgets('a refused edit is told once', (tester) async {
    final engine = await pumpNotice(tester, refuse: true);
    expect(
      find.text(
        'Eine Änderung ist für dein Konto nicht erlaubt und wurde '
        'zurückgenommen.',
      ),
      findsOneWidget,
    );
    expect(engine.takeRefusedChanges(), isEmpty, reason: 'told once');
  });

  testWidgets('without a reason (older server) nothing is told', (
    tester,
  ) async {
    await pumpNotice(tester, refuse: false);
    expect(find.byType(SnackBar), findsNothing);
  });
}
