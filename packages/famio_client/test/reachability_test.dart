import 'package:famio_client/famio_client.dart';
import 'package:test/test.dart';

void main() {
  test('a phone counts as reachable for half an hour, ntfy always', () {
    final recent = DateTime.now().subtract(const Duration(minutes: 5));
    final old = DateTime.now().subtract(const Duration(hours: 2));
    expect(Reachability(ownPush: recent).reachable, isTrue);
    expect(Reachability(ownPush: old).reachable, isFalse);
    expect(const Reachability().reachable, isFalse);
    expect(Reachability(ownPush: old, ntfy: 1).reachable, isTrue);
    final parsed = Reachability.fromJson({
      'ownPush': recent.toUtc().toIso8601String(),
      'ntfy': 0,
    });
    expect(parsed.reachable, isTrue);
  });
}
