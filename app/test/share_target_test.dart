import 'package:famio/src/screens/share_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shared lines lose bullets, numbers and check boxes', () {
    expect(
      shareLines('- Milch\n• Butter\n2. Brot\n[x] Eier\n☐ Salz\n\n  Käse  '),
      ['Milch', 'Butter', 'Brot', 'Eier', 'Salz', 'Käse'],
    );
    // A count stays: the shopping list reads it as the quantity.
    expect(shareLines('3 Äpfel'), ['3 Äpfel']);
  });
}
