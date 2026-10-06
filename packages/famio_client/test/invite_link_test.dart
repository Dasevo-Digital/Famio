import 'package:famio_client/famio_client.dart';
import 'package:test/test.dart';

void main() {
  test('an invitation QR code round-trips', () {
    const link = InviteLink(
      server: 'https://192.168.1.5:8766/',
      code: 'ABCD-EFGH',
      pin: 'AB:CD:EF',
    );
    final text = link.encode();
    expect(text, startsWith('famio-invite:'));
    final back = InviteLink.parse(text)!;
    expect(
      (back.server, back.code, back.pin),
      ('https://192.168.1.5:8766/', 'ABCD-EFGH', 'AB:CD:EF'),
    );
    expect(
      InviteLink.parse(
        const InviteLink(server: 'https://f.example', code: 'X').encode(),
      )!.pin,
      isNull,
    );
  });

  test('other codes are no invitations', () {
    expect(InviteLink.parse('4006381333931'), isNull);
    expect(InviteLink.parse('famio-invite:!!!'), isNull);
    expect(InviteLink.parse('famio-invite:e30'), isNull, reason: '{}');
  });
}
