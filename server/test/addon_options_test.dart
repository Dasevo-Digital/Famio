import 'package:famio_server/famio_server.dart';
import 'package:test/test.dart';

void main() {
  test('the server address of client mode, as typed in the options', () {
    String? read(String text) => upstreamAddress(text)?.toString();
    expect(read('https://famio.example.de'), 'https://famio.example.de');
    expect(read(' famio.example.de '), 'https://famio.example.de');
    expect(read('https://192.168.1.20:8766'), 'https://192.168.1.20:8766');
    expect(
      read('http://homeassistant.local:8765/famio'),
      'http://homeassistant.local:8765/famio',
    );
    for (final bad in [
      '',
      'ftp://famio.example.de',
      'https://',
      'famio example',
    ]) {
      expect(read(bad), isNull, reason: bad);
    }
  });
}
