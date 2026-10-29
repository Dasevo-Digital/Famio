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
  // Version 1 writers do not know about leases. Upgrading preserves their
  // copies, but prevents old tabs from reopening and recreating deleted data.
  final request = web.window.indexedDB.open(_database, 2);
  request.onupgradeneeded = ((web.Event _) {
    final db = request.result as web.IDBDatabase;
    if (!db.objectStoreNames.contains(_keys)) db.createObjectStore(_keys);
    if (!db.objectStoreNames.contains(_copies)) db.createObjectStore(_copies);
  }).toJS;
  request.onsuccess = ((web.Event _) {
    final db = request.result as web.IDBDatabase;
    db.onversionchange = ((web.Event _) => db.close()).toJS;
    done.complete(db);
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

Future<web.CryptoKey?> _key(web.IDBDatabase db, String name) async =>
    (await _run(_store(db, _keys, 'readonly').get(name.toJS)))
        as web.CryptoKey?;

/// The decrypted copy [name], or null (none, or not readable any more).
Future<Uint8List?> readBrowserCopy(String name) async {
  final db = await _open();
  try {
    final key = await _key(db, name);
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

String _leaseKey(String name) => 'lease:$name';

Future<void> _committed(web.IDBTransaction transaction) {
  final done = Completer<void>();
  transaction.oncomplete = ((web.Event _) {
    if (!done.isCompleted) done.complete();
  }).toJS;
  transaction.onabort = transaction.onerror = ((web.Event _) {
    if (!done.isCompleted) {
      done.completeError(StateError('IndexedDB transaction failed'));
    }
  }).toJS;
  return done.future;
}

web.IDBTransaction _copyTransaction(web.IDBDatabase db) =>
    db.transaction([_keys.toJS, _copies.toJS].toJS, 'readwrite');

/// Reserves a new generation before asynchronous key creation. A deletion
/// during key creation invalidates the reservation as well as any old writer.
Future<void> enableBrowserCopy(String name, String lease) async {
  final db = await _open();
  try {
    final reserve = _copyTransaction(db);
    final reserved = _committed(reserve);
    reserve.objectStore(_keys)
      ..put(lease.toJS, _leaseKey(name).toJS)
      ..delete(name.toJS);
    reserve.objectStore(_copies).delete(name.toJS);
    await reserved;
    final key = await web.window.crypto.subtle
        .generateKey(
          JSObject()
            ..setProperty('name'.toJS, 'AES-GCM'.toJS)
            ..setProperty('length'.toJS, 256.toJS),
          false,
          ['encrypt'.toJS, 'decrypt'.toJS].toJS,
        )
        .toDart;
    final transaction = _copyTransaction(db);
    final committed = _committed(transaction);
    final keys = transaction.objectStore(_keys);
    final check = keys.get(_leaseKey(name).toJS);
    check.onsuccess = ((web.Event _) {
      if ((check.result as JSString?)?.toDart == lease) {
        keys.put(key, name.toJS);
      }
    }).toJS;
    await committed;
  } finally {
    db.close();
  }
}

/// Only an explicitly enabled, still-current generation may commit. The
/// generation check and put share a transaction, also across browser tabs.
Future<void> writeBrowserCopy(
  String name,
  Uint8List plain,
  String lease,
) async {
  final db = await _open();
  try {
    final keys = _store(db, _keys, 'readonly');
    final current = _run(keys.get(_leaseKey(name).toJS));
    final keyRequest = _run(keys.get(name.toJS));
    final values = await Future.wait([current, keyRequest]);
    if ((values[0] as JSString?)?.toDart != lease) return;
    final key = values[1] as web.CryptoKey?;
    if (key == null) return;
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
    final transaction = _copyTransaction(db);
    final committed = _committed(transaction);
    final check = transaction.objectStore(_keys).get(_leaseKey(name).toJS);
    check.onsuccess = ((web.Event _) {
      if ((check.result as JSString?)?.toDart == lease) {
        transaction.objectStore(_copies).put(stored.toJS, name.toJS);
      }
    }).toJS;
    await committed;
  } finally {
    db.close();
  }
}

/// Removes the copy, key and write permission atomically. Old encryptions
/// cannot recreate a key or commit after this transaction.
Future<void> deleteBrowserCopy(String name) async {
  final db = await _open();
  try {
    final transaction = _copyTransaction(db);
    final committed = _committed(transaction);
    transaction.objectStore(_copies).delete(name.toJS);
    transaction.objectStore(_keys)
      ..delete(name.toJS)
      ..delete(_leaseKey(name).toJS);
    await committed;
  } finally {
    db.close();
  }
}
