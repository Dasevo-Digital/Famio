import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  Future<Response> get(FamioServerApp app, {String? token}) async =>
      app.handler(
        Request(
          'GET',
          Uri.parse('http://famio.test/metrics'),
          headers: {'authorization': ?(token == null ? null : 'Bearer $token')},
        ),
      );

  const token = 'metrics-token-0123456789';

  test('does not exist without a token', () async {
    final app = FamioServerApp.inMemory();
    expect((await get(app, token: token)).statusCode, 404);
  });

  test('needs the token, tells numbers but no family data', () async {
    final app = FamioServerApp.inMemory(metricsToken: token);
    final mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama Geheim',
      passwordHash: 'x',
    );
    app.accounts.create(
      username: 'kind',
      displayName: 'Kind',
      passwordHash: 'x',
      role: MemberRole.child,
    );
    app.records.sync(
      SyncRequest(
        since: 0,
        changes: [
          SyncRecord(
            collection: Collections.tasks,
            id: 't1',
            data: const Task(id: 't1', title: 'Arzttermin Kind').toData(),
            updatedAt: 1,
          ),
        ],
      ),
      mama.id,
    );
    await app.backups!.run();

    expect((await get(app)).statusCode, 401);
    expect((await get(app, token: 'falsch-falsch-falsch')).statusCode, 401);

    final response = await get(app, token: token);
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], startsWith('text/plain'));
    final text = await response.readAsString();
    expect(text, contains('famio_info{version="$serverVersion"} 1'));
    expect(text, contains('famio_members{role="adult"} 1'));
    expect(text, contains('famio_members{role="child"} 1'));
    expect(text, contains('famio_records 1'));
    expect(text, contains('famio_backups 1'));
    expect(text, contains('famio_backup_check_ok 1'));
    expect(text, contains('famio_backup_overdue 0'));
    expect(text, contains('famio_http_responses_total{class="4xx"} 2'));
    expect(text, contains('# TYPE famio_push_total counter'));
    // Nothing the family stores.
    for (final secret in ['Mama Geheim', 'mama', 'Arzttermin', 't1']) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
  });

  test('reports a backup that is overdue', () async {
    final app = FamioServerApp.inMemory(metricsToken: token);
    Future<String> text() async =>
        (await get(app, token: token)).readAsString();
    // A new server without a backup yet is not overdue.
    expect(await text(), contains('famio_backup_overdue 0'));

    // The nightly run stopped two days ago, without an error.
    final old = DateTime.now().subtract(const Duration(days: 2));
    String two(int n) => n.toString().padLeft(2, '0');
    Directory(
      '${app.backups!.dir}/famio-${old.year}${two(old.month)}${two(old.day)}-030000',
    ).createSync(recursive: true);
    final stale = await text();
    expect(stale, contains('famio_backup_overdue 1'));
    expect(stale, contains('famio_backup_failed 0'));

    await app.backups!.run();
    expect(await text(), contains('famio_backup_overdue 0'));
  });
}
