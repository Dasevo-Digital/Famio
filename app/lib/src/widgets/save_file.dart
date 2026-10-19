import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// Saves [bytes] where the user picks; false if they cancelled. In the
/// browser the file is downloaded, and the browser does not tell whether
/// or where: that counts as saved.
Future<bool> saveBytes({
  required String dialogTitle,
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
}) async {
  final saved = await FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    bytes: bytes,
    mimeType: mimeType,
  );
  return saved != null || kIsWeb;
}
