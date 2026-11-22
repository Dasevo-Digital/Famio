import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

/// Bookings of pocket money name their kind in the reader's language, also
/// those the server booked with the German note "Taschengeld" (#581).
void main() {
  tearDown(() => sharedTexts = (key, german) => german);

  MoneyEntry entry(String note, [MoneyKind kind = MoneyKind.allowance]) =>
      MoneyEntry(
        id: 'm',
        memberId: 'k',
        cents: 500,
        at: DateTime(2026, 11, 21),
        kind: kind,
        note: note,
      );

  test('the kind in the reader\'s language, the note where there is one', () {
    sharedTexts = (key, german) => sharedTranslation('en', key) ?? german;
    expect(entry('').title, 'Pocket money');
    expect(entry('Taschengeld').title, 'Pocket money');
    expect(entry('Oma hat was dazugegeben').title, 'Oma hat was dazugegeben');
    // The word as the note of another kind is the family's own.
    expect(entry('Taschengeld', MoneyKind.gift).title, 'Taschengeld');

    sharedTexts = (key, german) => sharedTranslation('es', key) ?? german;
    expect(entry('Taschengeld').title, 'Paga');
    sharedTexts = (key, german) => german;
    expect(entry('').title, 'Taschengeld');
  });
}
