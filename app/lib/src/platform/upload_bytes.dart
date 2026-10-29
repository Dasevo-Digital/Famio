import 'dart:typed_data';
import 'package:famio_client/famio_client.dart';

const maxLocalUploadBytes = 100 * 1024 * 1024;

/// Check metadata first, then enforce the same bound while reading. This also
/// covers unknown sizes and files that grow after the picker returned.
Future<Uint8List> readUploadBytes({
  required Future<int?> Function() length,
  required Stream<List<int>> Function() openRead,
}) async {
  if ((await length() ?? 0) > maxLocalUploadBytes) {
    throw ApiError(413, 'too_large', ClientTexts.transferTooLarge);
  }
  try {
    return await readTransferBytes(openRead(), maxBytes: maxLocalUploadBytes);
  } on TransferTooLarge {
    throw ApiError(413, 'too_large', ClientTexts.transferTooLarge);
  }
}
