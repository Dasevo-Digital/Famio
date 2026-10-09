import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('famio_access_'));
  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+rwx', dir.path]);
    dir.deleteSync(recursive: true);
  });

  test('a usable data folder passes and stays clean', () {
    final data = p.join(dir.path, 'data');
    expect(dataAccessProblem(data, p.join(dir.path, 'famio.key')), isNull);
    expect(Directory(data).listSync(), isEmpty);
  });

  test('says what to do when the folder or the key is not accessible', () {
    final data = Directory(p.join(dir.path, 'data'))..createSync();
    final key = File(p.join(dir.path, 'famio.key'))..writeAsStringSync('x');
    Process.runSync('chmod', ['000', key.path]);
    final keyProblem = dataAccessProblem(data.path, key.path, docker: true);
    expect(keyProblem, contains('Schlüsseldatei'));
    expect(keyProblem, contains('sudo chown -R 65532:65532 data keys'));

    Process.runSync('chmod', ['555', data.path]);
    final folder = dataAccessProblem(data.path, key.path, docker: false);
    expect(folder, contains('Kein Schreibzugriff'));
    expect(folder, isNot(contains('65532')));
  }, testOn: '!windows');
}
