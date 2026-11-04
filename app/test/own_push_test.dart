import 'dart:convert';

import 'package:famio/src/push/own_push.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _notice(int id) => {
  'id': id,
  'at': DateTime(2026, 11, 4, 17).toIso8601String(),
  'title': 'Neue Anmeldung',
  'body': 'Famio auf einem neuen Gerät',
  'tag': 'key',
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a notice the system will not show does not stop the later ones',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      // The first call starts after the newest notice; then two batches.
      final batches = [
        {'notices': <Object?>[], 'last': 0},
        {
          'notices': [_notice(1), _notice(2)],
          'last': 2,
        },
        {
          'notices': [_notice(3)],
          'last': 3,
        },
      ];
      final api = FamioApiClient(
        'localhost:1',
        httpClient: MockClient((request) async {
          if (batches.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return _json({'notices': [], 'last': 3});
          }
          return _json(batches.removeAt(0));
        }),
      );
      final shown = <int>[];
      final push = OwnPush(
        prefs,
        show: (notice, {required details}) async {
          // Like a Linux desktop without a notification service.
          if (notice.id == 1) throw StateError('no notification service');
          shown.add(notice.id);
        },
      );
      await push.attach(
        api,
        serverUrl: 'localhost:1',
        pin: null,
        device: 'Mac',
      );
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (shown.length < 2 && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await push.detach();
      expect(shown, [2, 3]);
    },
  );
}
