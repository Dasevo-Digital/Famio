import 'package:famio/src/data/family_data.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SyncEngine engine;
  final start = DateTime(2026, 11, 6, 12);
  final direct = ChatIds.direct('m1', 'm2');
  final others = ChatIds.direct('m2', 'k1');

  void message(
    String id,
    String chat,
    String author,
    int minute, {
    bool withoutChat = false,
  }) => engine.put(Collections.chatMessages, id, {
    ...ChatMessage(
      id: id,
      chatId: chat,
      authorId: author,
      sentAt: start.add(Duration(minutes: minute)),
    ).toData(),
    if (withoutChat) 'chatId': null,
  });

  setUp(() {
    engine = SyncEngine(
      store: LocalStore.open(':memory:')
        ..setMeta(
          'members',
          '[{"id":"m1","username":"mama","displayName":"Mama"},'
              '{"id":"m2","username":"papa","displayName":"Papa"},'
              '{"id":"k1","username":"mia","displayName":"Mia"}]',
        ),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    message('a', ChatIds.family, 'm2', 1);
    message('b', ChatIds.family, 'm1', 2);
    message('c', direct, 'm2', 3);
    message('d', others, 'm2', 4);
    // Older apps did not write the chat: the family's.
    message('e', '', 'k1', 5, withoutChat: true);
  });

  test('counts what others wrote in the chats of this member', () {
    expect(engine.unreadCount(ChatIds.family), 2);
    expect(engine.unreadCount(direct), 1);
    expect(engine.totalUnread, 3);
    expect(engine.chatMessages(ChatIds.family).map((m) => m.id), [
      'a',
      'b',
      'e',
    ]);
  });

  test('a read chat only counts what came after', () {
    engine.markChatRead(
      ChatIds.family,
      at: start.add(const Duration(minutes: 1)),
    );
    expect(engine.unreadCount(ChatIds.family), 1);
    expect(engine.totalUnread, 2);
    engine.markChatRead(direct, at: start.add(const Duration(minutes: 9)));
    expect(engine.totalUnread, 1);
  });

  test('a new message counts at once, not only after the next change', () {
    message('f', ChatIds.family, 'k1', 6);
    expect(engine.totalUnread, 4);
    expect(engine.latestChatMessage?.id, 'f');
  });

  test('the newest message of all chats', () {
    expect(engine.latestChatMessage?.id, 'e');
    engine.deleteChatMessage('e');
    expect(engine.latestChatMessage?.id, 'd');
  });
}
