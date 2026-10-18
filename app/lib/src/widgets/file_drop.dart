import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../l10n.dart';
import '../platform/opened_files.dart';

/// Desktop: files dragged onto the window are shared to Famio. They are
/// read right away (the macOS sandbox allows it only during the drop) into
/// copies in the temporary folder; the originals are never touched, the
/// copies are removed after use like shared files on Android.
class FileDropZone extends StatefulWidget {
  const FileDropZone({super.key, required this.child, required this.onFiles});

  final Widget child;
  final void Function(List<SharedFile> files) onFiles;

  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  @override
  State<FileDropZone> createState() => _FileDropZoneState();
}

class _FileDropZoneState extends State<FileDropZone> {
  var _over = false;

  static const _maxFiles = 10;
  static const _maxBytes = 100 * 1024 * 1024;

  Future<void> _take(List<DropItem> items) async {
    final dir = Directory(
      p.join((await getTemporaryDirectory()).path, 'famio-drop'),
    )..createSync(recursive: true);
    final files = <SharedFile>[];
    for (final item in items.take(_maxFiles)) {
      if (FileSystemEntity.isDirectorySync(item.path)) continue;
      final bookmark = item.extraAppleBookmark;
      final scoped =
          Platform.isMacOS &&
          bookmark != null &&
          bookmark.isNotEmpty &&
          await DesktopDrop.instance.startAccessingSecurityScopedResource(
            bookmark: bookmark,
          );
      try {
        if (await item.length() > _maxBytes) continue;
        final bytes = await item.readAsBytes();
        final name = item.name.isEmpty ? p.basename(item.path) : item.name;
        final copy = File(
          p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}-$name'),
        )..writeAsBytesSync(bytes);
        files.add((
          path: copy.path,
          name: name,
          mime:
              lookupMimeType(name, headerBytes: bytes.take(64).toList()) ??
              'application/octet-stream',
        ));
      } on FileSystemException {
        // Not readable (e.g. a folder or a vanished file): left out.
      } finally {
        if (scoped) {
          await DesktopDrop.instance.stopAccessingSecurityScopedResource(
            bookmark: bookmark,
          );
        }
      }
    }
    if (files.isNotEmpty && mounted) widget.onFiles(files);
  }

  @override
  Widget build(BuildContext context) {
    if (!FileDropZone.supported) return widget.child;
    final theme = Theme.of(context);
    return DropTarget(
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: (details) {
        setState(() => _over = false);
        _take(details.files);
      },
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),
          if (_over)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  child: Center(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          tr.dropHere,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
