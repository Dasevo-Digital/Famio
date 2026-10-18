import 'package:famio_server/src/auth/password_rules.dart';
import 'package:test/test.dart';

void main() {
  test('common passwords and their variants are too weak', () {
    for (final pw in [
      'passwort',
      'Passwort1',
      'P@ssw0rt2024!',
      'geheim123',
      'qwertz123',
      'fussball1',
      'ichliebedich',
      '12345678',
      '87654321',
      'aaaaaaaa',
      'abcabcabc',
      'asdfghjk',
      '19861205',
      'ab123456',
    ]) {
      expect(PasswordRules.isWeak(pw), isTrue, reason: pw);
    }
  });

  test('a family name with a few characters around it is too weak', () {
    const family = ['mama', 'Mama Müller', 'lukas', 'Lukas'];
    expect(PasswordRules.isWeak('Lukas2015!', personal: family), isTrue);
    expect(PasswordRules.isWeak('mueller-1', personal: ['Müller']), isFalse);
    expect(PasswordRules.isWeak('müller12', personal: family), isTrue);
    // A name as one word among others is fine.
    expect(
      PasswordRules.isWeak('mamas-blauer-kuehlschrank', personal: family),
      isFalse,
    );
  });

  test('random words and long numbers pass', () {
    for (final pw in [
      'tulpe-regal-wolke',
      'Kp9!zuX2qR',
      '839201746381',
      'geheim-regal-7',
      'neu-geheim-9',
    ]) {
      expect(PasswordRules.isWeak(pw), isFalse, reason: pw);
    }
  });
}
