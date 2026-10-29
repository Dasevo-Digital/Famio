import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import '../design/app_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../platform/browser.dart';
import '../platform/upload_bytes.dart';
import '../platform/document_scanner.dart';
import 'photo_viewer.dart';
import '../design/palette.dart';
import '../format.dart';
import '../l10n.dart';

/// A file picked by the user, ready for upload.
class PickedFile {
  const PickedFile(this.bytes, this.name, this.mime)
    : _source = null,
      sourceLength = null,
      path = null;
  const PickedFile.stream(
    this._source,
    this.name,
    this.mime, {
    this.sourceLength,
    this.path,
  }) : bytes = null;

  final List<int>? bytes;
  final String? path;
  final Stream<List<int>> Function()? _source;
  final int? sourceLength;
  int? get length => bytes?.length ?? sourceLength;
  Stream<List<int>> openRead() => _source?.call() ?? Stream.value(bytes!);
  final String name;
  final String mime;
}

int uploadLimit(SyncEngine engine) => kIsWeb
    ? engine.maxUploadBytes.clamp(1, maxBrowserFileBytes)
    : engine.maxUploadBytes;

Future<PickedFile> pickedFromSource({
  required String name,
  required Stream<List<int>> Function() openRead,
  required Future<int?> Function() length,
  required int maxBytes,
  String? mime,
  String? path,
}) async {
  final size = await length();
  if ((size ?? 0) > maxBytes) {
    throw ApiError(
      413,
      'too_large',
      tr.filesUploadLimit(fileSizeLabel(maxBytes)),
    );
  }
  if (!kIsWeb && (size == null || size > 8 * 1024 * 1024)) {
    return PickedFile.stream(
      openRead,
      name,
      mime ?? lookupMimeType(name) ?? 'application/octet-stream',
      sourceLength: size,
      path: path,
    );
  }
  final bytes = await readUploadBytes(
    length: () async => size,
    openRead: openRead,
    maxBytes: maxBytes,
  );
  return PickedFile(
    bytes,
    name,
    mime ??
        lookupMimeType(name, headerBytes: bytes.take(64).toList()) ??
        'application/octet-stream',
  );
}

bool get _hasCamera => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Lets the user pick a file; on phones photos can also come from the
/// camera, and letters can be scanned into a PDF.
Future<PickedFile?> pickFile(
  BuildContext context, {
  bool imagesOnly = false,
}) async {
  final limit = uploadLimit(AppScope.read(context).engine!);
  var fromCamera = false;
  final scan = !imagesOnly && canScanDocuments;
  if (_hasCamera || kIsWeb) {
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
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(tr.filesUploadLimit(fileSizeLabel(limit))),
              ),
              if (_hasCamera)
                ListTile(
                  leading: const Icon(AppIcons.camera),
                  title: Text(tr.importTakePhoto),
                  onTap: () => Navigator.pop(context, 'camera'),
                ),
              if (scan)
                ListTile(
                  leading: const Icon(AppIcons.scanText),
                  title: Text(tr.filesScanDocument),
                  subtitle: Text(tr.filesScanDocumentHint),
                  onTap: () => Navigator.pop(context, 'scan'),
                ),
              ListTile(
                leading: Icon(
                  imagesOnly ? AppIcons.images : AppIcons.fileArrowUp,
                ),
                title: Text(
                  imagesOnly ? tr.filesGallery : tr.filesChooseFilePhoto,
                ),
                onTap: () => Navigator.pop(context, 'file'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return null;
    if (choice == 'scan') {
      if (!context.mounted) return null;
      return _scan(context);
    }
    fromCamera = choice == 'camera';
  }

  if (fromCamera) {
    final photo = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      maxWidth: 2560,
    );
    if (photo == null) return null;
    return pickedFromSource(
      name: photo.name,
      length: photo.length,
      openRead: photo.openRead,
      maxBytes: limit,
      mime: 'image/jpeg',
    );
  }

  final picked = await FilePicker.pickFiles(
    type: imagesOnly ? FileType.image : FileType.any,
    dialogTitle: tr.filesUploadLimit(fileSizeLabel(limit)),
  );
  if (picked.isEmpty) return null;
  final file = picked.first;
  return pickedFromSource(
    name: file.name,
    path: file.path,
    length: file.length,
    openRead: file.readAsByteStream,
    maxBytes: limit,
  );
}

/// A letter or form from the phone's document scanner, as one PDF.
Future<PickedFile?> _scan(BuildContext context) async {
  final limit = uploadLimit(AppScope.read(context).engine!);
  try {
    final pdf = await scanDocument();
    if (pdf == null || pdf.isEmpty) return null;
    if (pdf.length > limit) {
      throw ApiError(413, 'too_large', ClientTexts.transferTooLarge);
    }
    final stamp = DateFormat('yyyy-MM-dd HH.mm').format(DateTime.now());
    return PickedFile(pdf, '${tr.filesScanName} $stamp.pdf', 'application/pdf');
  } on PlatformException {
    // A dialog: a snack bar would be hidden behind the editor sheet.
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(tr.filesScanUnavailable),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr.commonOk),
            ),
          ],
        ),
      );
    }
    return null;
  }
}

/// Uploads [file] and keeps a local copy, so it opens instantly and offline.
Future<FileRef> uploadPicked(BuildContext context, PickedFile file) async {
  return uploadPickedState(AppScope.read(context), file);
}

Future<FileRef> uploadPickedState(AppState state, PickedFile file) async {
  final engine = state.engine!;
  final cache = state.files;
  final limit = uploadLimit(engine);
  final bytes = file.bytes;
  if (bytes == null) {
    if (cache != null) {
      return cache.uploadStream(
        openRead: file.openRead,
        name: file.name,
        mime: file.mime,
        length: file.length,
        maxBytes: limit,
      );
    }
    return engine.api.uploadFileStream(
      stream: file.openRead(),
      name: file.name,
      mime: file.mime,
      length: file.length,
      maxBytes: limit,
    );
  }
  return cache == null
      ? engine.api.uploadFile(bytes: bytes, name: file.name, mime: file.mime)
      : cache.uploadBytes(bytes: bytes, name: file.name, mime: file.mime);
}

/// Opens a file: pictures in Famio's own viewer, together with the other
/// pictures of [gallery] to go through; everything else in the device's
/// app for it (PDF viewer …), in the browser as a download.
Future<void> openFileRef(
  BuildContext context,
  FileRef ref, {
  List<FileRef> gallery = const [],
}) async {
  if (ref.isImage && ref.size <= maxBrowserFileBytes) {
    final photos = [
      for (final f in gallery)
        if (f.isImage && f.size <= maxBrowserFileBytes) f,
    ];
    if (!photos.any((f) => f.id == ref.id)) photos.insert(0, ref);
    return showPhotoViewer(
      context,
      photos,
      initial: photos.indexWhere((f) => f.id == ref.id),
    );
  }
  return openFileExternally(context, ref);
}

/// Hands [ref] to the device's app for it; in the browser a download.
Future<void> openFileExternally(BuildContext context, FileRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final files = AppScope.read(context).files!;
    if (kIsWeb) {
      if (ref.size > maxBrowserFileBytes) {
        throw ApiError(413, 'too_large', tr.filesBrowserLimit);
      }
      downloadBytes(await files.bytes(ref), ref.name, ref.mime);
      return;
    }
    // A short-lived plain copy for the other app; removed on next start.
    final path = await files.openable(ref);
    if (Platform.isAndroid || Platform.isIOS) {
      await OpenFilex.open(path, type: ref.mime);
    } else {
      await launchUrl(Uri.file(path));
    }
  } on ApiError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// Image from the file cache (downloading a server-side thumbnail once).
class CachedImage extends StatefulWidget {
  const CachedImage(
    this.ref, {
    super.key,
    this.thumb = 480,
    this.fit = BoxFit.cover,
    this.radius = 18,
    this.onDark = false,
  });

  final FileRef ref;
  final int? thumb;
  final BoxFit fit;
  final double radius;

  /// On black (viewer, slideshow): no light box while it loads.
  final bool onDark;

  @override
  State<CachedImage> createState() => _CachedImageState();
}

class _CachedImageState extends State<CachedImage> {
  FileCache? _files;
  Future<Uint8List>? _bytes;

  /// Loads once per file, not on every rebuild of the screen around it.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final files = AppScope.of(context).files;
    if (files != _files) {
      _files = files;
      _load();
    }
  }

  @override
  void didUpdateWidget(CachedImage old) {
    super.didUpdateWidget(old);
    if (old.ref.id != widget.ref.id || old.thumb != widget.thumb) _load();
  }

  void _load() => _bytes = _files?.bytes(widget.ref, thumb: widget.thumb);

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    Widget placeholder([IconData icon = AppIcons.image]) => Container(
      color: widget.onDark ? Colors.transparent : c.surfaceSoft,
      alignment: Alignment.center,
      child: Icon(
        icon,
        color: widget.onDark ? Colors.white54 : c.inkSoft,
        size: 32,
      ),
    );
    final bytes = _bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: bytes == null
          ? placeholder()
          : FutureBuilder<Uint8List>(
              future: bytes,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return placeholder(AppIcons.imageBroken);
                }
                if (!snapshot.hasData) return placeholder();
                return Image.memory(
                  snapshot.data!,
                  gaplessPlayback: true,
                  fit: widget.fit,
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
  return '${decimal(bytes / (1024 * 1024))} MB';
}
