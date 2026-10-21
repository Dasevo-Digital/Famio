import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../design/app_icons.dart';
import '../l10n.dart';
import 'files.dart';

/// Pictures in Famio itself instead of a download or another app: one
/// after the other with a swipe, the arrow keys or the arrows at the sides;
/// bigger with two fingers, the mouse wheel or a double tap. The button at
/// the top still hands the picture on (in the browser as a download).
Future<void> showPhotoViewer(
  BuildContext context,
  List<FileRef> photos, {
  int initial = 0,
}) => Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder<void>(
    pageBuilder: (_, _, _) => PhotoViewer(photos: photos, initial: initial),
    transitionsBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  ),
);

class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.photos, this.initial = 0});

  final List<FileRef> photos;
  final int initial;

  /// Shown at once, a fraction of a camera's original …
  static const previewSize = 1920;

  /// … until the original is there, decoded at most this big: sharp when
  /// zoomed, without a 50-megapixel photo filling the memory.
  static const maxSide = 4096;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late final _pages = PageController(initialPage: widget.initial);
  late var _index = widget.initial;

  /// The zoom of the picture on screen; while it is zoomed, a swipe moves
  /// the picture instead of turning to the next one.
  final _zoom = TransformationController();
  var _zoomed = false;
  Offset _tapped = Offset.zero;

  @override
  void dispose() {
    _pages.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.photos.length) return;
    _pages.animateToPage(
      next,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _zoomChanged() {
    final zoomed = _zoom.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  /// A double tap zooms in where it was, and out again.
  void _toggleZoom() {
    const scale = 2.5;
    _zoom.value = _zoomed
        ? Matrix4.identity()
        : (Matrix4.diagonal3Values(scale, scale, 1)..setTranslationRaw(
            -_tapped.dx * (scale - 1),
            -_tapped.dy * (scale - 1),
            0,
          ));
    _zoomChanged();
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    final many = photos.length > 1;
    // Arrows at the sides where a mouse can't swipe.
    final arrows = many && MediaQuery.sizeOf(context).width >= 600;
    void close() => Navigator.of(context).pop();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): close,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          color: Colors.black,
          child: Stack(
            children: [
              PageView.builder(
                controller: _pages,
                physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
                itemCount: photos.length,
                onPageChanged: (i) => setState(() {
                  _index = i;
                  _zoom.value = Matrix4.identity();
                  _zoomed = false;
                }),
                itemBuilder: (context, i) => GestureDetector(
                  onDoubleTapDown: (d) => _tapped = d.localPosition,
                  onDoubleTap: i == _index ? _toggleZoom : null,
                  child: InteractiveViewer(
                    transformationController: i == _index ? _zoom : null,
                    maxScale: 5,
                    onInteractionEnd: (_) => _zoomChanged(),
                    child: SizedBox.expand(child: _Picture(photos[i])),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        _RoundButton(
                          icon: AppIcons.x,
                          tooltip: tr.commonClose,
                          onPressed: close,
                        ),
                        if (many)
                          Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: Text(
                              '${_index + 1} / ${photos.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                shadows: [
                                  Shadow(blurRadius: 8, color: Colors.black),
                                ],
                              ),
                            ),
                          ),
                        const Spacer(),
                        _RoundButton(
                          icon: kIsWeb
                              ? AppIcons.cloudArrowDown
                              : AppIcons.arrowSquareOut,
                          tooltip: kIsWeb
                              ? tr.photoViewerDownload
                              : tr.photoViewerOpenWith,
                          onPressed: () =>
                              openFileExternally(context, photos[_index]),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (arrows && _index > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _RoundButton(
                      icon: AppIcons.caretLeft,
                      tooltip: tr.photoViewerPrevious,
                      onPressed: () => _go(-1),
                    ),
                  ),
                ),
              if (arrows && _index < photos.length - 1)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _RoundButton(
                      icon: AppIcons.caretRight,
                      tooltip: tr.photoViewerNext,
                      onPressed: () => _go(1),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The preview at once, the original in its place as soon as it is loaded
/// and decoded. An original the device cannot show (HEIC on Windows …)
/// leaves the preview.
class _Picture extends StatefulWidget {
  const _Picture(this.photo);

  final FileRef photo;

  @override
  State<_Picture> createState() => _PictureState();
}

class _PictureState extends State<_Picture> {
  FileCache? _files;
  Future<Uint8List>? _original;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final files = AppScope.of(context).files;
    if (files != _files) {
      _files = files;
      _original = files?.bytes(widget.photo);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = CachedImage(
      widget.photo,
      thumb: PhotoViewer.previewSize,
      fit: BoxFit.contain,
      radius: 0,
      onDark: true,
    );
    return FutureBuilder<Uint8List>(
      future: _original,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return preview;
        return Image(
          image: ResizeImage(
            MemoryImage(bytes),
            width: PhotoViewer.maxSide,
            height: PhotoViewer.maxSide,
            policy: ResizeImagePolicy.fit,
            allowUpscaling: false,
          ),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, _) =>
              frame == null ? preview : child,
          errorBuilder: (_, _, _) => preview,
        );
      },
    );
  }
}

/// White on a dark round, readable on any picture.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton.filled(
    icon: Icon(icon),
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: Colors.black54,
      foregroundColor: Colors.white,
      minimumSize: const Size.square(48),
    ),
  );
}
