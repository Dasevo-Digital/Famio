// A notification's link from ntfy carries only a key (#578); the app asks
// its server what it opens. Unknown keys and older servers open nothing.
import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  FamioApiClient api(http.Response Function(http.Request) answer) =>
      FamioApiClient(
        'https://famio.test',
        token: 't',
        httpClient: MockClient((request) async => answer(request)),
      );

  http.Response json(String body, int status) => http.Response(
    body,
    status,
    headers: {'content-type': 'application/json'},
  );

  test('the key becomes what the notification is about', () async {
    final asked = <Uri>[];
    final target = await api((request) {
      asked.add(request.url);
      return json('{"target":"chat:family"}', 200);
    }).noticeTarget('R4nd0mKeyOfANotice_123');
    expect(target, const NoticeTarget.chat('family'));
    expect(asked.single.path, '/api/notifications/link/R4nd0mKeyOfANotice_123');
  });

  test('unknown to the server (or an older one): nothing to open', () async {
    expect(
      await api(
        (_) => json('{"error":"not_found","message":"x"}', 404),
      ).noticeTarget('R4nd0mKeyOfANotice_123'),
      isNull,
    );
    expect(
      await api((_) => http.Response('Not found', 404)).noticeTarget('k' * 22),
      isNull,
    );
  });

  test('other failures are reported', () async {
    await expectLater(
      api(
        (_) => json('{"error":"unauthorized","message":"x"}', 401),
      ).noticeTarget('R4nd0mKeyOfANotice_123'),
      throwsA(isA<ApiError>()),
    );
  });

  test('links: only the key, and only valid ones are read back', () {
    final link = Uri.parse(NoticeLink.of('R4nd0mKeyOfANotice_123'));
    expect(link.toString(), 'famio://open?notice=R4nd0mKeyOfANotice_123');
    expect(NoticeLink.keyOf(link), 'R4nd0mKeyOfANotice_123');
    expect(NoticeLink.keyIn('notice:R4nd0mKeyOfANotice_123'), isNotNull);
    expect(NoticeLink.keyIn('notice:short'), isNull);
    expect(NoticeLink.keyIn('notice:../../etc'), isNull);
    expect(NoticeLink.keyIn('task:t1'), isNull);
    expect(
      NoticeLink.keyOf(Uri.parse('famio://open?target=task%3At1')),
      isNull,
    );
  });
}
