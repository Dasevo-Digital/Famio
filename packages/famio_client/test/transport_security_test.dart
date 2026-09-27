import 'package:famio_client/famio_client.dart';
import 'package:test/test.dart';

void main() {
  TransportSecurity of(String input) =>
      FamioApiClient.transportSecurity(FamioApiClient.normalizeUrl(input));

  test('https is encrypted', () {
    expect(of('https://famio.example.org'), TransportSecurity.encrypted);
  });

  test('plain http inside the home network is allowed', () {
    for (final host in [
      '192.168.1.164',
      '10.0.0.5:8765',
      '172.20.1.1',
      'localhost',
      'homeassistant.local:8765',
      'nas',
      '100.101.1.2', // Tailscale
      'http://[fd00::1]:8765',
    ]) {
      expect(of(host), TransportSecurity.localNetwork, reason: host);
    }
  });

  test('plain http to the internet is insecure', () {
    for (final host in [
      'famio.example.org',
      'http://famio.example.org',
      '8.8.8.8',
      '172.32.0.1',
    ]) {
      expect(of(host), TransportSecurity.insecure, reason: host);
    }
  });
}
