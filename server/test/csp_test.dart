import 'package:famio_server/famio_server.dart';
import 'package:test/test.dart';

void main() {
  String connect(String csp) =>
      RegExp(r'connect-src ([^;]*)').firstMatch(csp)![1]!;

  test('the web app reaches only the hosts it needs', () {
    final hosts = connect(WebApp.policyFor()).split(' ');
    expect(hosts, [
      "'self'",
      'https://api.open-meteo.com',
      'https://world.openfoodfacts.org',
      'https://api.github.com',
      'https://tile.openstreetmap.org',
    ]);
  });

  test('an own tile server is allowed instead, placeholders as wildcard', () {
    expect(
      connect(
        WebApp.policyFor(
          tileUrl: 'https://karten.example.org:8443/t/{z}/{x}/{y}',
        ),
      ),
      endsWith('https://karten.example.org:8443'),
    );
    expect(
      connect(
        WebApp.policyFor(
          tileUrl: 'https://{s}.tiles.example.org/{z}/{x}/{y}.png',
        ),
      ),
      endsWith('https://*.tiles.example.org'),
    );
    // Nothing odd slips into the header.
    expect(
      connect(WebApp.policyFor(tileUrl: "https://evil.example; script-src *")),
      isNot(contains('script-src')),
    );
  });
}
