// Checks a release folder like the server and the apps do: the signature
// of SHA256SUMS.txt with the built-in release key, and for every package
// the apps install the checksum the signed list names. Exit code 1 if
// anything does not fit.
//
//   cd packages/famio_shared && dart run tool/verify_release.dart <folder> <version>
import 'dart:io';

import 'package:famio_shared/famio_shared.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'Aufruf: dart run tool/verify_release.dart <Ordner> <Version>',
    );
    exit(64);
  }
  final [dir, version] = args;
  final sums = File('$dir/SHA256SUMS.txt').readAsStringSync();
  final sig = File('$dir/SHA256SUMS.txt.sig').readAsStringSync();
  var ok = await verifyReleaseSignature(sums, sig);
  print('Signatur: ${ok ? 'gültig' : 'UNGÜLTIG'}');
  for (final p in AppPlatform.values) {
    final name = p.fileName(version);
    final expected = await signedChecksum(sums, sig, name);
    final file = File('$dir/$name');
    final actual = file.existsSync() ? await sha256Hex(file.openRead()) : null;
    final fits = expected != null && expected == actual;
    ok &= fits;
    print('$name: ${fits ? 'passt' : 'FEHLT ODER FALSCH'}');
  }
  if (!ok) exit(1);
}
