import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() => sharedTexts = (key, german) => german);

  test('German stays as it is without a translation', () {
    expect(MemberRole.guest.label, 'Gast');
    expect(localizeServerText('Nicht angemeldet'), 'Nicht angemeldet');
  });

  test('stored server messages are translated, also with values', () {
    sharedTexts = (key, german) => sharedTranslation('en', key) ?? german;
    expect(MemberRole.guest.label, 'Guest');
    expect(
      localizeServerText('Kalender nicht gefunden (HTTP 404)'),
      'Calendar not found (HTTP 404)',
    );
    expect(
      localizeServerText('Abgleich fehlgeschlagen: Keine Kalender gefunden'),
      'Sync failed: No calendars found',
    );
    expect(
      localizeServerText(
        'Famio 5, dort 7 Einträge; 1 gesendet, 2 übernommen, 0 gelöscht',
      ),
      'Famio 5, there 7 entries; 1 sent, 2 taken over, 0 deleted',
    );
    expect(localizeServerText('etwas Unbekanntes'), 'etwas Unbekanntes');
  });

  test('placeholders are filled after the translation', () {
    sharedTexts = (key, german) => sharedTranslation('es', key) ?? german;
    expect(
      sharedText('Server|Hallo {name}!', 'Hallo {name}!', {'name': 'Ana'}),
      '¡Hola, Ana!',
    );
  });
}
