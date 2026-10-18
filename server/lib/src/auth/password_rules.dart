/// Passwords that are too easy to guess, checked whenever one is set:
/// the most common passwords and words, keyboard rows and number
/// sequences, short numbers (a date of birth) and the names of the
/// family's own members, each with a few digits or symbols around it
/// ("Mama2024!", "Passw0rt1"). Offline: nothing leaves the server.
///
/// Passwords already in use are not checked again; they keep working.
abstract final class PasswordRules {
  /// Whether [password] is too easy to guess. [personal]: names and user
  /// names of the members (and similar words) that must not be the core
  /// of the password.
  static bool isWeak(String password, {Iterable<String> personal = const []}) {
    final lower = password.toLowerCase();
    if (_repeats(lower) || _inSequence(lower)) return true;
    if (!RegExp(r'[a-zäöüß]').hasMatch(lower)) {
      // Digits and symbols only: a date of birth or a PIN is quickly tried.
      return password.length < 12;
    }
    // Without digits and symbols at the ends, read like letters:
    // "P@ssw0rt2024!" → "passwort".
    final core = _unleet(
      lower.replaceAll(RegExp(r'^[^a-zäöüß@$€]+|[^a-zäöüß@$€]+$'), ''),
    );
    if (core.length < 4) return true;
    if (_common.contains(core) || _repeats(core) || _inSequence(core)) {
      return true;
    }
    for (final word in personal) {
      for (final part in _unleet(
        word.toLowerCase(),
      ).split(RegExp(r'[\s._-]+'))) {
        if (part.length < 3) continue;
        // A name with a few characters around it is no better than the name.
        if (core.contains(part) && core.length - part.length < 4) return true;
      }
    }
    return false;
  }

  /// "p@ssw0rt" reads as "passwort".
  static String _unleet(String s) => s
      .replaceAll('0', 'o')
      .replaceAll('1', 'i')
      .replaceAll('3', 'e')
      .replaceAll('4', 'a')
      .replaceAll('5', 's')
      .replaceAll('7', 't')
      .replaceAll('@', 'a')
      .replaceAll(r'$', 's')
      .replaceAll('€', 'e');

  /// "aaaaaaaa", "abcabcabc", "12121212".
  static bool _repeats(String s) {
    for (var unit = 1; unit <= s.length ~/ 2; unit++) {
      if (s.length % unit != 0) continue;
      final head = s.substring(0, unit);
      if (head * (s.length ~/ unit) == s) return true;
    }
    return false;
  }

  static bool _inSequence(String s) {
    if (s.length < 4) return false;
    for (final row in _sequences) {
      if (row.contains(s) || row.split('').reversed.join().contains(s)) {
        return true;
      }
    }
    return false;
  }

  static const _sequences = [
    '01234567890',
    'abcdefghijklmnopqrstuvwxyz',
    'qwertzuiopü',
    'qwertyuiop',
    'asdfghjklöä',
    'yxcvbnm',
    'zxcvbnm',
    '1qay2wsx3edc4rfv5tgb',
    '1qaz2wsx3edc4rfv5tgb',
    'qayxswedcvfrtgb',
  ];

  /// Common passwords and the words they are made of (German and
  /// English), without digits and symbols at the ends.
  static const _common = {
    'passwort',
    'password',
    'passwd',
    'kennwort',
    'geheim',
    'geheimnis',
    'secret',
    'hallo',
    'hello',
    'hallihallo',
    'qwertz',
    'qwerty',
    'asdf',
    'asdfgh',
    'yxcvbn',
    'schatz',
    'schatzi',
    'liebe',
    'liebling',
    'ichliebedich',
    'iloveyou',
    'loveyou',
    'love',
    'sommer',
    'winter',
    'fruehling',
    'frühling',
    'herbst',
    'sonne',
    'sonnenschein',
    'sunshine',
    'blume',
    'blumen',
    'fussball',
    'fußball',
    'football',
    'soccer',
    'baseball',
    'basketball',
    'bayern',
    'fcbayern',
    'borussia',
    'bvb',
    'schalke',
    'werder',
    'hsv',
    'eintracht',
    'deutschland',
    'germany',
    'berlin',
    'hamburg',
    'muenchen',
    'münchen',
    'koeln',
    'köln',
    'familie',
    'family',
    'famio',
    'mama',
    'papa',
    'mami',
    'papi',
    'mutter',
    'vater',
    'kinder',
    'kind',
    'baby',
    'oma',
    'opa',
    'hase',
    'hasi',
    'maus',
    'mausi',
    'engel',
    'prinzessin',
    'princess',
    'prinz',
    'dragon',
    'drache',
    'monkey',
    'affe',
    'tiger',
    'loewe',
    'löwe',
    'pferd',
    'hund',
    'katze',
    'master',
    'admin',
    'administrator',
    'root',
    'login',
    'anmelden',
    'welcome',
    'willkommen',
    'test',
    'testtest',
    'tester',
    'demo',
    'abc',
    'abcd',
    'letmein',
    'trustno',
    'superman',
    'batman',
    'spiderman',
    'starwars',
    'pokemon',
    'minecraft',
    'shadow',
    'computer',
    'internet',
    'google',
    'samsung',
    'apple',
    'iphone',
    'android',
    'handy',
    'telefon',
    'zuhause',
    'home',
    'haus',
    'garten',
    'urlaub',
    'freiheit',
    'freedom',
    'freund',
    'freundin',
    'friend',
    'friends',
    'ficken',
    'fuck',
    'arsch',
    'scheisse',
    'scheiße',
    'killer',
    'hunter',
    'jordan',
    'ranger',
    'harley',
    'mercedes',
    'porsche',
    'ferrari',
    'audi',
    'bmw',
    'golf',
    'schule',
    'school',
    'student',
    'chocolate',
    'schokolade',
    'cookie',
    'keks',
    'pizza',
    'banane',
    'banana',
    'apfel',
    'erdbeere',
    'kaffee',
    'coffee',
    'bier',
    'whisky',
    'matrix',
    'ninja',
    'pass',
    'passport',
    'zugang',
    'access',
    'changeme',
    'aendern',
    'ändern',
    'start',
    'starten',
    'default',
    'standard',
    'nichts',
    'nothing',
    'egal',
    'whatever',
    'ichbins',
    'itsme',
    'meins',
    'mine',
    'privat',
    'private',
    'sicher',
    'sicherheit',
    'security',
    'qwertzu',
    'qwertzui',
    'qwertyui',
    'azerty',
    'muster',
    'mustermann',
    'beispiel',
    'example',
    'gott',
    'jesus',
    'lucky',
    'glueck',
    'glück',
    'gluecklich',
    'happy',
    'smile',
    'lachen',
    'traum',
    'dream',
    'zauber',
    'magic',
    'stern',
    'star',
    'mond',
    'moon',
    'himmel',
    'heaven',
    'herz',
    'heart',
    'schnecke',
    'teddy',
    'kuschel',
  };
}
