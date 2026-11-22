// The web app removes `?open=` from the address once it has read it, so a
// reload does not open the same notification target again (#579).
import 'package:famio/src/platform/open_request_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the open request leaves the address, the rest stays', () {
    expect(
      addressWithoutOpenRequest(
        Uri.parse('https://famio.example/?open=task%3At1'),
      ),
      '/',
    );
    expect(
      addressWithoutOpenRequest(
        Uri.parse('https://famio.example/famio/?a=1&open=task%3At1&b=2#/home'),
      ),
      '/famio/?a=1&b=2#/home',
    );
    expect(
      addressWithoutOpenRequest(Uri.parse('https://famio.example/?open=')),
      '/',
    );
  });

  test('nothing to remove: the address stays as it is', () {
    expect(
      addressWithoutOpenRequest(Uri.parse('https://famio.example/')),
      isNull,
    );
    expect(
      addressWithoutOpenRequest(Uri.parse('https://famio.example/?opened=1')),
      isNull,
    );
  });
}
