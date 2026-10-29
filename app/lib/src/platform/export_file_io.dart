import 'dart:io';
import 'package:famio_client/famio_client.dart';
import 'dart:ui';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

/// Writes exclusively to a new file; failures leave no partial archive.
Future<void> writeExportFile(
  File file,
  Future<void> Function(IOSink) write, {
  void Function()? onFailure,
}) async {
  await file.create(exclusive: true);
  final sink = file.openWrite();
  var complete = false;
  // Observe disk errors even while the network is waiting for the next chunk.
  final failure = sink.done.then<void>(
    (_) {},
    onError: (Object e, StackTrace s) => Error.throwWithStackTrace(e, s),
  );
  Future<void>? writing;
  try {
    writing = write(sink);
    await Future.any([writing, failure]);
    await sink.flush();
    await sink.close();
    complete = true;
  } catch (_) {
    onFailure?.call();
    try {
      await writing;
    } catch (_) {}
    rethrow;
  } finally {
    if (!complete) {
      try {
        await sink.close();
      } catch (_) {}
      if (await file.exists()) await file.delete();
    }
  }
}

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
  final mobile = Platform.isAndroid || Platform.isIOS;
  final directory = mobile
      ? tempDir
      : await FilePicker.getDirectoryPath(dialogTitle: dialogTitle);
  if (directory == null || cancellation.cancelled) return false;
  await Directory(directory).create(recursive: true);
  final file = File(
    p.join(
      directory,
      '${p.basenameWithoutExtension(fileName)}-${newId().substring(0, 8)}.zip',
    ),
  );
  var handedOff = false;
  try {
    await writeExportFile(
      file,
      (sink) => api.exportDataToSink(
        sink,
        password: password,
        family: family,
        cancellation: cancellation,
        onProgress: onProgress,
      ),
      onFailure: cancellation.cancel,
    );
    if (cancellation.cancelled) return false;
    if (mobile) {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/zip')],
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
      handedOff = result.status != ShareResultStatus.dismissed;
      return handedOff;
    }
    handedOff = true;
    return true;
  } catch (_) {
    cancellation.cancel();
    rethrow;
  } finally {
    // Shared files remain until the account's next startup/sign-out cleanup.
    if (!handedOff && await file.exists()) await file.delete();
  }
}
