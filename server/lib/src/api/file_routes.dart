part of '../api.dart';

/// File upload and download.
extension _FileRoutes on FamioApi {
  Future<Response> _upload(Request request) async {
    final member = _auth(request);
    _checkWriter(member);
    final length = request.contentLength;
    if (length != null && length > files.maxBytes) {
      throw ApiException(
        413,
        'too_large',
        t('Datei ist größer als {mb} MB', {
          'mb': files.maxBytes ~/ (1024 * 1024),
        }),
      );
    }
    final name = request.url.queryParameters['name'] ?? 'datei';
    final mime =
        request.headers['content-type']?.split(';').first.trim() ??
        'application/octet-stream';
    final file = await files.save(
      owner: member.id,
      name: name,
      mime: mime.isEmpty ? 'application/octet-stream' : mime,
      body: request.read(),
    );
    return _json(file.toJson(), status: 201);
  }

  Future<Response> _download(Request request, String id) async {
    final member = _auth(request);
    if (id.startsWith(PaperBuddyLink.idPrefix)) {
      return _paperBuddyFile(request, id, member);
    }
    final file = files.get(id);
    // Same answer for "missing" and "forbidden": ids reveal nothing.
    if (file == null || !files.mayRead(file, member.id)) {
      throw ApiException(404, 'not_found', t('Datei nicht gefunden'));
    }
    final thumb = int.tryParse(request.url.queryParameters['thumb'] ?? '');
    final Stream<List<int>> body;
    final int length;
    if (thumb == null) {
      body = files.read(file);
      length = file.size;
    } else {
      final jpeg = await files.thumbnail(file, thumb);
      if (jpeg == null) {
        throw ApiException(404, 'not_found', t('Keine Vorschau verfügbar'));
      }
      body = Stream.value(jpeg);
      length = jpeg.length;
    }
    return Response.ok(
      body,
      headers: {
        ..._fileHeaders(file.name, thumb == null ? file.mime : 'image/jpeg'),
        'content-length': '$length',
        // Files never change; a new upload gets a new id.
        'cache-control': 'private, max-age=31536000, immutable',
      },
    );
  }
}
