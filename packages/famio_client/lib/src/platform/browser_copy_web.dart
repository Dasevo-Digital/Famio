import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// The web app's copy of a store, kept only when the member asked for it:
// encrypted with AES-GCM under a key WebCrypto created as not extractable
// (scripts can use it, but cannot read it out), both in IndexedDB. Signing
// out deletes copy and key.

const _database = 'famio-browser-copy';
const _keys = 'keys';
const _copies = 'copies';

Future<web.IDBDatabase> _open() {
  final done = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open(_database, 1);
  request.onupgradeneeded = ((web.Event _) {
    final db = request.result as web.IDBDatabase;
    if (!db.objectStoreNames.contains(_keys)) db.createObjectStore(_keys);
    if (!db.objectStoreNames.contains(_copies)) db.createObjectStore(_copies);
  }).toJS;
  request.onsuccess = ((web.Event _) {
    done.complete(request.result as web.IDBDatabase);
  }).toJS;
  request.onerror = ((web.Event _) {
    done.completeError(StateError('IndexedDB nicht verfügbar'));
  }).toJS;
  return done.future;
}

Future<JSAny?> _run(web.IDBRequest request) {
  final done = Completer<JSAny?>();
  request.onsuccess = ((web.Event _) => done.complete(request.result)).toJS;
  request.onerror = ((web.Event _) {
    done.completeError(StateError('IndexedDB: ${request.error?.message}'));
  }).toJS;
  return done.future;
}

/// AES-GCM with [iv]: the algorithm object for encrypt and decrypt.
JSObject _gcm(Uint8List iv) => JSObject()
  ..setProperty('name'.toJS, 'AES-GCM'.toJS)
  ..setProperty('iv'.toJS, iv.toJS);

web.IDBObjectStore _store(web.IDBDatabase db, String name, String mode) =>
    db.transaction(name.toJS, mode).objectStore(name);

Future<web.CryptoKey?> _key(
  web.IDBDatabase db,
  String name, {
  required bool create,
}) async {
  final stored = await _run(_store(db, _keys, 'readonly').get(name.toJS));
  if (stored != null) return stored as web.CryptoKey;
  if (!create) return null;
  final key =
      await web.window.crypto.subtle
              .generateKey(
                JSObject()
                  ..setProperty('name'.toJS, 'AES-GCM'.toJS)
                  ..setProperty('length'.toJS, 256.toJS),
                false,
                ['encrypt'.toJS, 'decrypt'.toJS].toJS,
              )
              .toDart
          as web.CryptoKey;
  await _run(_store(db, _keys, 'readwrite').put(key, name.toJS));
  return key;
}

/// The decrypted copy [name], or null (none, or not readable any more).
Future<Uint8List?> readBrowserCopy(String name) async {
  final db = await _open();
  try {
    final key = await _key(db, name, create: false);
    final stored = await _run(_store(db, _copies, 'readonly').get(name.toJS));
    if (key == null || stored == null) return null;
    final bytes = (stored as JSUint8Array).toDart;
    final plain =
        await web.window.crypto.subtle
                .decrypt(
                  _gcm(Uint8List.sublistView(bytes, 0, 12)),
                  key,
                  Uint8List.sublistView(bytes, 12).toJS,
                )
                .toDart
            as JSArrayBuffer;
    return plain.toDart.asUint8List();
  } on Object {
    return null;
  } finally {
    db.close();
  }
}

/// Encrypts [plain] and keeps it as copy [name] (a new IV each time).
Future<void> writeBrowserCopy(String name, Uint8List plain) async {
  final db = await _open();
  try {
    final key = (await _key(db, name, create: true))!;
    final random = Random.secure();
    final iv = Uint8List.fromList([
      for (var i = 0; i < 12; i++) random.nextInt(256),
    ]);
    final cipher =
        await web.window.crypto.subtle.encrypt(_gcm(iv), key, plain.toJS).toDart
            as JSArrayBuffer;
    final stored = Uint8List(12 + cipher.toDart.lengthInBytes)
      ..setAll(0, iv)
      ..setAll(12, cipher.toDart.asUint8List());
    await _run(_store(db, _copies, 'readwrite').put(stored.toJS, name.toJS));
  } finally {
    db.close();
  }
}

/// Removes copy [name] and its key.
Future<void> deleteBrowserCopy(String name) async {
  final db = await _open();
  try {
    await _run(_store(db, _copies, 'readwrite').delete(name.toJS));
    await _run(_store(db, _keys, 'readwrite').delete(name.toJS));
  } finally {
    db.close();
  }
}
