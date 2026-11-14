/// What to do with an on-device database its key does not open (another
/// key, a damaged file, one written by another library version).
enum UnreadableDatabase {
  /// An error (tests, desktops by default before #490).
  fail,

  /// Delete it and start anew: its key is gone for good. A phone restored
  /// from the backup of another one gets the file back but not the key,
  /// which stays in the keystore of the old device (#490).
  reset,

  /// Keep it under another name and start anew: the key is this device's,
  /// so the file is damaged or from another version, and what it holds that
  /// the server does not have yet may be rescued from it (#490).
  setAside,
}

final _setAside = <String>[];

/// The databases set aside since the last call (see
/// [UnreadableDatabase.setAside]), by the name they keep.
List<String> takeSetAsideDatabases() {
  final taken = [..._setAside];
  _setAside.clear();
  return taken;
}

/// Records that the database at [path] was set aside (for the platform
/// implementations).
void noteSetAside(String path) => _setAside.add(path);
