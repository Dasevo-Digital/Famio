import 'dart:typed_data';
import 'dart:io';
import 'package:famio_client/famio_client.dart';

const maxLocalUploadBytes = 100 * 1024 * 1024;
const maxBrowserFileBytes = FamioApiClient.maxBufferedFileBytes;
const maxNativeFileBytes = 4096 * 1024 * 1024;

/// Check metadata first, then enforce the same bound while reading. This also
/// covers unknown sizes and files that grow after the picker returned.
Future<Uint8List> readUploadBytes({
  required Future<int?> Function() length,
  required Stream<List<int>> Function() openRead,
  int maxBytes = maxLocalUploadBytes,
}) async {
  if ((await length() ?? 0) > maxBytes) {
    throw ApiError(413, 'too_large', ClientTexts.transferTooLarge);
  }
  try {
    return await readTransferBytes(openRead(), maxBytes: maxBytes);
  } on TransferTooLarge {
    throw ApiError(413, 'too_large', ClientTexts.transferTooLarge);
  }
}

Future<void> copyUploadFile(
  File target,
  Stream<List<int>> source, {
  required int maxBytes,
}) async {
  final output = await target.open(mode: FileMode.writeOnly);
  var complete = false;
  try {
    await for (final chunk in limitedTransferStream(
      source,
      maxBytes: maxBytes,
    )) {
      await output.writeFrom(chunk);
    }
    complete = true;
  } finally {
    await output.close();
    if (!complete && await target.exists()) await target.delete();
  }
}
