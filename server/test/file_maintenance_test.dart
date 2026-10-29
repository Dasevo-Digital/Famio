import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:image/image.dart' as img;
import 'package:image/src/formats/gif/gif_image_desc.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late FamilyMember owner, other;
  setUp(() {
    app = FamioServerApp.inMemory();
    owner = app.accounts.create(username: 'owner', displayName: 'Owner');
    other = app.accounts.create(username: 'other', displayName: 'Other');
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });
  test(
    'reference index follows edits, quarantine repair and failed transactions',
    () async {
      final file = await app.files.save(
        owner: owner.id,
        name: 'fixture',
        mime: 'text/plain',
        body: Stream.value([1]),
      );
      final ref = FileRef(
        id: file.id,
        name: file.name,
        mime: file.mime,
        size: file.size,
      );
      SyncRecord document(Map<String, Object?> data) => SyncRecord(
        collection: Collections.documents,
        id: 'document',
        updatedAt: 1,
        data: data,
      );
      app.records.writeAsServer([
        document({'title': 'Attached', 'file': ref.toJson()}),
      ]);
      expect(app.records.referencedFor(file.id, other.id), isTrue);
      app.db.execute('BEGIN');
      app.db.execute('UPDATE records SET data = ?, rev = rev + 1', [
        '{"title":"Transient"}',
      ]);
      expect(app.records.referenced(file.id), isFalse);
      app.db.execute('ROLLBACK');
      expect(app.records.referenced(file.id), isTrue);
      app.records.writeAsServer([
        document({'title': 42, 'file': ref.toJson()}),
      ]);
      expect(app.records.referenced(file.id), isTrue);
      expect(app.records.referencedFor(file.id, other.id), isFalse);
      app.records.writeAsServer([
        document({'title': 'Repaired without attachment'}),
      ]);
      expect(app.records.referenced(file.id), isFalse);
    },
  );
  test(
    'batched garbage collection yields and retains a new reference during maintenance',
    () async {
      for (var i = 0; i < 160; i++) {
        app.db.execute(
          'INSERT INTO files (id, owner, name, mime, size, created_at) VALUES (?, ?, ?, ?, 1, 0)',
          [
            'f${i.toString().padLeft(3, '0')}',
            owner.id,
            'fixture',
            'text/plain',
          ],
        );
      }
      var yielded = false;
      Timer.run(() {
        yielded = true;
        app.records.writeAsServer([
          SyncRecord(
            collection: Collections.documents,
            id: 'retained',
            updatedAt: 1,
            data: {
              'title': 'New during collection',
              'file': const FileRef(
                id: 'f159',
                name: 'fixture',
                mime: 'text/plain',
                size: 1,
              ).toJson(),
            },
          ),
        ]);
      });
      final run = app.files.collectGarbageAsync();
      expect(identical(run, app.files.collectGarbageAsync()), isTrue);
      expect(await run, 159);
      expect(yielded, isTrue);
      expect(app.files.get('f159'), isNotNull);
    },
  );
  test(
    'thumbnail decodes the first frame even when a later frame is damaged',
    () async {
      final animation = img.Image(width: 16, height: 16);
      img.fill(animation, color: img.ColorRgb8(240, 10, 10));
      animation.addFrame(img.Image(width: 16, height: 16));
      final bytes = Uint8List.fromList(img.encodeGif(animation));
      final decoder = img.GifDecoder();
      final info = decoder.startDecode(bytes)!;
      // Move the unused frame outside the canvas. Header traversal and the
      // first frame remain valid; decoding the entire animation rejects it.
      final frame = info.frames[1] as InternalGifImageDesc;
      final descriptor =
          frame.inputPosition - 9 - (frame.colorMap?.numColors ?? 0) * 3;
      bytes[descriptor] = 17;
      bytes[descriptor + 1] = 0;
      expect(img.GifDecoder().decode(bytes), isNull);
      final file = await app.files.save(
        owner: owner.id,
        name: 'animation.gif',
        mime: 'image/gif',
        body: Stream.value(bytes),
      );
      final jpeg = await app.files.thumbnail(file, 160);
      expect(jpeg, isNotNull);
      final image = img.decodeJpg(jpeg!)!;
      expect(image.width, 16);
      expect(image.getPixel(0, 0).r, greaterThan(200));
    },
  );
}
