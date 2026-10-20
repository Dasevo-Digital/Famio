import 'dart:convert';
import 'dart:typed_data';

import 'package:famio_shared/famio_shared.dart';

/// What the web app keeps of a store in the browser (when the member asked
/// for it): the records with their "still to send" flag and the metadata.
typedef StoreSnapshot = ({
  List<(SyncRecord, bool)> records,
  Map<String, String> meta,
});

/// The snapshot as bytes (UTF-8 JSON), to be encrypted.
Uint8List encodeSnapshot(StoreSnapshot snapshot) => utf8.encode(
  jsonEncode({
    'v': 1,
    'records': [
      for (final (record, dirty) in snapshot.records)
        {...record.toJson(), 'dirty': dirty},
    ],
    'meta': snapshot.meta,
  }),
);

/// Null if [bytes] are no snapshot of this format.
StoreSnapshot? decodeSnapshot(Uint8List bytes) {
  try {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    if (json['v'] != 1) return null;
    return (
      records: [
        for (final r in json['records'] as List)
          (
            SyncRecord.fromJson((r as Map).cast<String, Object?>()),
            r['dirty'] == true,
          ),
      ],
      meta: (json['meta'] as Map).cast<String, String>(),
    );
  } on Object {
    return null;
  }
}
