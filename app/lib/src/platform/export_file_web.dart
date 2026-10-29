import 'dart:typed_data';
import 'package:famio_client/famio_client.dart';
import 'dart:ui';
import '../widgets/save_file.dart';

Future<bool> saveExport({
  required FamioApiClient api,
  required String password,
  required bool family,
  required String tempDir,
  required String fileName,
  required String dialogTitle,
  required TransferCancellation cancellation,
  Rect? sharePositionOrigin,
  required void Function(int, int?) onProgress,
}) async {
  final bytes = await api.exportData(
    password: password,
    family: family,
    cancellation: cancellation,
    onProgress: onProgress,
  );
  if (cancellation.cancelled) return false;
  return saveBytes(
    dialogTitle: dialogTitle,
    fileName: fileName,
    bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    mimeType: 'application/zip',
  );
}
