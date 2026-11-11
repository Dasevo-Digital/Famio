// Famio's own trips to the camera, the file pickers, the scanner and the
// share sheet go through AppLock.picking: else "lock at once" would ask for
// the fingerprint after every photo (#393).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every picker Famio opens is announced to the app lock', () {
    final calls = RegExp(
      r'FilePicker\.(pickFiles|saveFile|getDirectoryPath)\(|'
      r'ImagePicker\(\)\.pick\w*\(|'
      r'SharePlus\.instance\.share\(|'
      r"invokeMethod<Uint8List>\('scan'\)",
    );
    final found = <String>[];
    final missing = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!calls.hasMatch(lines[i])) continue;
        found.add('${file.path}:${i + 1}');
        final around = lines.sublist(i < 2 ? 0 : i - 2, i + 1).join('\n');
        if (!around.contains('AppLock.picking(')) {
          missing.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(found, isNotEmpty);
    expect(missing, isEmpty);
  });
}
