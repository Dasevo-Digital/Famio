import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('the dictionary knows the usual things', () {
    expect(guessShoppingCategory('Vollmilch'), 'dairy');
    expect(guessShoppingCategory('3 Äpfel'), 'produce');
    expect(guessShoppingCategory('Spaghetti'), 'pantry');
    expect(guessShoppingCategory('Klopapier'), 'household');
    expect(guessShoppingCategory('Windeln Gr. 4'), 'baby');
    expect(guessShoppingCategory('Hackfleisch'), 'meat');
    expect(guessShoppingCategory('Mineralwasser'), 'drinks');
    expect(guessShoppingCategory('Irgendwas'), 'other');
  });

  test('the longest match wins; "Ei" is not "Eis"', () {
    expect(guessShoppingCategory('Eis'), 'frozen');
    expect(guessShoppingCategory('Ei'), 'dairy');
    expect(guessShoppingCategory('Eier'), 'dairy');
    // "schokostreusel" (baking) beats "schoko" (snacks).
    expect(guessShoppingCategory('Schokostreusel'), 'baking');
  });

  test("the family's correction wins", () {
    final learned = {shoppingKey('Hafermilch'): 'drinks'};
    expect(guessShoppingCategory('Hafermilch'), 'dairy');
    expect(guessShoppingCategory('hafermilch', learned: learned), 'drinks');
    expect(shoppingKey('  2x  Hafer   Milch '), 'hafer milch');
  });
}
