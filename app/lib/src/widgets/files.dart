import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import '../design/app_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../design/palette.dart';

/// A file picked by the user, ready for upload.
class PickedFile {
  const PickedFile(this.bytes, this.name, this.mime);

  final List<int> bytes;
  final String name;
  final String mime;
}

bool get _hasCamera => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Lets the user pick a file; on phones photos can also come from the camera.
Future<PickedFile?> pickFile(
  BuildContext context, {
  bool imagesOnly = false,
}) async {
  var fromCamera = false;
  if (_hasCamera) {
    final choice = await showModalBottomSheet<String>(
      context: context,
      // Above the floating navigation bar.
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(AppIcons.camera),
                title: const Text('Foto aufnehmen'),
                onTap: () => Navigator.pop(context, 'camera'),
              ),
              ListTile(
                leading: Icon(
                  imagesOnly ? AppIcons.images : AppIcons.fileArrowUp,
                ),
                title: Text(
                  imagesOnly ? 'Aus der Galerie' : 'Datei oder Foto auswählen',
                ),
                onTap: () => Navigator.pop(context, 'file'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return null;
    fromCamera = choice == 'camera';
  }

  if (fromCamera) {
    final photo = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      maxWidth: 2560,
    );
    if (photo == null) return null;
    return PickedFile(await photo.readAsBytes(), photo.name, 'image/jpeg');
  }

  final picked = await FilePicker.pickFiles(
    type: imagesOnly ? FileType.image : FileType.any,
  );
  if (picked.isEmpty) return null;
  final file = picked.first;
  final bytes = await file.readAsBytes();
  return PickedFile(
    bytes,
    file.name,
    lookupMimeType(file.name, headerBytes: bytes.take(64).toList()) ??
        'application/octet-stream',
  );
}

/// Uploads [file] and keeps a local copy, so it opens instantly and offline.
Future<FileRef> uploadPicked(BuildContext context, PickedFile file) async {
  final state = AppScope.read(context);
  final ref = await state.engine!.api.uploadFile(
    bytes: file.bytes,
    name: file.name,
    mime: file.mime,
  );
  state.files?.put(ref, file.bytes);
  return ref;
}

/// Opens a file with the system's default app (PDF viewer, image viewer, …).
Future<void> openFileRef(BuildContext context, FileRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    // A short-lived plain copy for the other app; removed on next start.
    final file = await AppScope.read(context).files!.openable(ref);
    if (Platform.isAndroid || Platform.isIOS) {
      await OpenFilex.open(file.path, type: ref.mime);
    } else {
      await launchUrl(Uri.file(file.path));
    }
  } on ApiError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// Image from the file cache (downloading a server-side thumbnail once).
class CachedImage extends StatelessWidget {
  const CachedImage(
    this.ref, {
    super.key,
    this.thumb = 480,
    this.fit = BoxFit.cover,
    this.radius = 18,
  });

  final FileRef ref;
  final int? thumb;
  final BoxFit fit;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final files = AppScope.of(context).files;
    final c = FamioColors.of(context);
    Widget placeholder([IconData icon = AppIcons.image]) => Container(
      color: c.surfaceSoft,
      alignment: Alignment.center,
      child: Icon(icon, color: c.inkSoft, size: 32),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: files == null
          ? placeholder()
          : FutureBuilder<Uint8List>(
              future: files.bytes(ref, thumb: thumb),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return placeholder(AppIcons.imageBroken);
                }
                if (!snapshot.hasData) return placeholder();
                return Image.memory(
                  snapshot.data!,
                  gaplessPlayback: true,
                  fit: fit,
                  errorBuilder: (_, _, _) => placeholder(AppIcons.imageBroken),
                );
              },
            ),
    );
  }
}

/// Icon matching a file's type.
IconData fileIcon(String mime) => switch (mime) {
  final m when m.startsWith('image/') => AppIcons.fileImage,
  'application/pdf' => AppIcons.filePdf,
  final m when m.contains('word') || m.contains('document') => AppIcons.fileDoc,
  final m when m.contains('sheet') || m.contains('excel') => AppIcons.fileXls,
  final m when m.startsWith('video/') => AppIcons.fileVideo,
  final m when m.startsWith('audio/') => AppIcons.fileAudio,
  _ => AppIcons.file,
};

String fileSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} MB';
}
