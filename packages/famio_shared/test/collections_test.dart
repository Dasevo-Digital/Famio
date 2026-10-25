import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('every collection with rules is also one the server syncs', () {
    // The server answers "unsupported" for collections outside
    // Collections.all: their records would stay on the device that wrote
    // them, without any error (absences until 2.0.17).
    for (final (name, set) in [
      ('conflictTracked', Collections.conflictTracked),
      ('guestReadable', Collections.guestReadable),
      ('guestWritable', Collections.guestWritable),
      ('adultOnly', Collections.adultOnly),
      ('adultReadable', Collections.adultReadable),
      ('serverOwned', Collections.serverOwned),
    ]) {
      expect(
        set.difference(Collections.all),
        isEmpty,
        reason: '$name has collections the server does not sync',
      );
    }
  });
}
