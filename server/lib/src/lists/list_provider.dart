/// Lists in other apps (Bring!, Microsoft To Do) that Famio keeps in sync
/// with its tasks and shopping lists, see [ListSync](list_sync.dart).
library;

/// A list in the other app.
class RemoteList {
  const RemoteList({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};
}

/// An entry there, reduced to what Famio maps: for tasks the title, note,
/// due day and whether it is done; for shopping the name, the quantity (as
/// [note]) and whether it is ticked off.
class RemoteItem {
  const RemoteItem({
    required this.id,
    required this.title,
    this.note = '',
    this.done = false,
    this.due,
    this.modified,
  });

  final String id;
  final String title;
  final String note;
  final bool done;

  /// The due day (local midnight), if the app has one.
  final DateTime? due;

  /// When it last changed there, if the app tells; decides conflicts.
  final DateTime? modified;
}

/// What Famio wants an entry to be.
class ItemDraft {
  const ItemDraft({
    required this.title,
    this.note = '',
    this.done = false,
    this.due,
  });

  final String title;
  final String note;
  final bool done;
  final DateTime? due;
}

/// The other app's interface.
abstract class ListProvider {
  /// `bring` or `mstodo`.
  String get kind;

  /// Whether entries with the same title are the same thing (Bring! keeps
  /// one entry per article name). Then a first sync links them instead of
  /// creating duplicates.
  bool get oneEntryPerTitle;

  /// Whether the app has due dates (Bring! does not).
  bool get hasDueDates;

  Future<List<RemoteList>> lists();

  Future<List<RemoteItem>> items(String listId);

  Future<RemoteItem> create(String listId, ItemDraft item);

  Future<void> update(String listId, RemoteItem previous, ItemDraft item);

  Future<void> delete(String listId, RemoteItem item);

  /// Credentials to store after a call (e.g. a renewed token).
  Map<String, Object?> get credentials;
}

/// A call to the other app failed. [signedOut]: the login is no longer
/// valid and the member has to connect again.
class ListProviderException implements Exception {
  ListProviderException(this.message, {this.signedOut = false});

  final String message;
  final bool signedOut;

  @override
  String toString() => message;
}
