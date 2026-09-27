import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Tracks connected WebSocket clients and nudges them when data changes.
///
/// Messages are only hints (`{"type":"rev","rev":n}`); clients then pull via
/// `/api/sync`, so a missed message costs latency, never data.
class ChangeHub {
  final _clients = <WebSocketChannel>{};

  int get connectedClients => _clients.length;

  void add(WebSocketChannel channel, {required int rev}) {
    _clients.add(channel);
    channel.sink.add(jsonEncode({'type': 'rev', 'rev': rev}));
    channel.stream.listen(
      (_) {}, // Clients only send pings; nothing to do.
      onDone: () => _clients.remove(channel),
      onError: (_) => _clients.remove(channel),
      cancelOnError: true,
    );
  }

  void notifyRev(int rev) => _broadcast({'type': 'rev', 'rev': rev});

  void notifyMembersChanged() => _broadcast({'type': 'members'});

  void _broadcast(Map<String, Object?> message) {
    final text = jsonEncode(message);
    for (final client in _clients.toList()) {
      client.sink.add(text);
    }
  }

  Future<void> close() async {
    for (final client in _clients.toList()) {
      await client.sink.close();
    }
    _clients.clear();
  }
}
