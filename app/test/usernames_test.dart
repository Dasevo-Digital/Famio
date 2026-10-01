import 'package:famio/src/data/usernames.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('names become login names the server accepts', () {
    expect(suggestUsername('Jürgen Müller', const []), 'juergen.mueller');
    expect(suggestUsername('Größe', const []), 'groesse');
    expect(suggestUsername('  Léa-Marie  ', const []), 'lea-marie');
    expect(suggestUsername("Emil 'Krümel' 🐻", const []), 'emil.kruemel');
    expect(suggestUsername('O', const []), 'o1');
    expect(suggestUsername('🐻', const []), '');
    expect(suggestUsername('A' * 50, const []).length, 30);
    for (final name in ['Jürgen Müller', 'Léa-Marie', 'Ömer Şahin', 'O']) {
      expect(isValidUsername(suggestUsername(name, const [])), isTrue);
    }
  });

  test('taken names are numbered', () {
    expect(suggestUsername('Lena', const ['lena']), 'lena2');
    expect(suggestUsername('Lena', const ['Lena', 'lena2']), 'lena3');
  });

  test('problems are explained before the server refuses them', () {
    expect(usernameProblem(''), isNull);
    expect(usernameProblem('jürgen'), isNotNull);
    expect(usernameProblem('a'), 'Mindestens 2 Zeichen');
    expect(usernameProblem('max mustermann'), isNotNull);
    expect(usernameProblem('max.mustermann'), isNull);
  });
}
