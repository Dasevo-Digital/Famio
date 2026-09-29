import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';

const _escape = HtmlEscape();

/// The page's only script (password form); allowed by its hash, so no
/// other script could run even if some text slipped through unescaped.
const _script = """
      document.getElementById('pw').addEventListener('submit', async (e) => {
        e.preventDefault();
        const body = Object.fromEntries(new FormData(e.target));
        const res = await fetch('api/me/password', {method: 'PUT', headers: {'content-type': 'application/json'}, body: JSON.stringify(body)});
        const data = await res.json();
        document.getElementById('msg').textContent = res.ok ? 'Gespeichert.' : data.message;
        if (res.ok) e.target.reset();
      });
    """;

/// Content-Security-Policy for the pages of this file.
final landingPagePolicy =
    "default-src 'none'; style-src 'unsafe-inline'; "
    "script-src 'sha256-${base64.encode(sha256.convert(utf8.encode(_script)).bytes)}'; "
    "connect-src 'self'; base-uri 'none'; form-action 'none'; "
    "frame-ancestors 'self'";

/// The page shown at `/`, mainly inside the Home Assistant sidebar (ingress).
/// It tells members how to connect the apps and lets HA users set a password
/// for app logins.
String landingPage({
  required FamilyMember? member,
  required bool hasPassword,
  required String address,
  required String version,
  bool addon = false,
  bool webApp = false,
}) {
  final serverUrl = const HtmlEscape(HtmlEscapeMode.element).convert(address);
  final memberSection = member == null
      ? '''
    <p>Der Server läuft. Verbinde die Famio-App mit dieser Adresse:</p>
    <p class="url">$serverUrl</p>'''
      : '''
    <p>Hallo <b>${_escape.convert(member.displayName)}</b>!</p>
    <p>Die Famio-App verbindest du mit:</p>
    <p class="url">$serverUrl</p>
    <p>Benutzername: <b>${_escape.convert(member.username)}</b></p>
    <h2>${hasPassword ? 'Passwort ändern' : 'Passwort für die App festlegen'}</h2>
    <form id="pw">
      ${hasPassword ? '<input type="password" name="currentPassword" placeholder="Aktuelles Passwort" required>' : ''}
      <input type="password" name="newPassword" placeholder="Neues Passwort (min. 8 Zeichen)" minlength="8" required>
      <button>Speichern</button>
      <p id="msg"></p>
    </form>
    <script>$_script</script>''';

  return '''<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Famio</title>
<style>
  :root { color-scheme: light dark; --accent: #3f7d6e; }
  body { font-family: system-ui, sans-serif; max-width: 34rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; }
  h1 { color: var(--accent); margin-bottom: 0; }
  .url { font-family: ui-monospace, monospace; font-size: 1.1rem; padding: .5rem .75rem; border-radius: .5rem; background: color-mix(in srgb, var(--accent) 15%, transparent); }
  input, button { display: block; width: 100%; box-sizing: border-box; margin: .4rem 0; padding: .6rem; font: inherit; border-radius: .4rem; border: 1px solid #8888; }
  button { background: var(--accent); color: white; border: none; cursor: pointer; }
  small { opacity: .6; }
  a { color: var(--accent); font-weight: 600; }
</style>
</head>
<body>
  <h1>Famio</h1>
  <small>Server $version${addon ? ' · Port in den Add-on-Einstellungen änderbar' : ''}</small>
  $memberSection${webApp ? '''
  <p><a href="app/">${addon ? '← Zurück zu Famio' : 'Famio im Browser öffnen'}</a></p>''' : ''}
</body>
</html>''';
}

/// Shown in the browser after signing in with the single sign-on provider.
String ssoResultPage({required bool ok, required String message}) =>
    '''<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Famio</title>
<style>
  :root { color-scheme: light dark; --accent: #3f7d6e; }
  body { font-family: system-ui, sans-serif; max-width: 30rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.5; text-align: center; }
  h1 { color: var(--accent); }
  .icon { font-size: 3rem; }
</style>
</head>
<body>
  <div class="icon">${ok ? '✅' : '⚠️'}</div>
  <h1>Famio</h1>
  <p>${_escape.convert(message)}</p>
</body>
</html>''';

/// Public Store listing destination for account deletion. It intentionally
/// carries no account data and sends a member to the signed-in web app, where
/// the deletion is protected by password and, when enabled, MFA.
String accountDeletionPage({required bool webApp}) =>
    '''<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Famio – Konto löschen</title><style>
:root { color-scheme: light dark; --accent: #3f7d6e; }
body { font-family: system-ui,sans-serif; max-width:34rem; margin:3rem auto; padding:0 1rem; line-height:1.5; }
h1,a { color:var(--accent); } a { font-weight:600; }
</style></head><body><h1>Famio-Konto löschen</h1>
<p>Du kannst dein Famio-Konto selbst löschen. Dabei werden Zugang, Sitzungen und persönliche Verbindungen entfernt; gemeinsam genutzte Familieneinträge bleiben für die anderen Mitglieder erhalten.</p>
${webApp ? '<p><a href="app/">Bei Famio anmelden und Konto löschen</a></p>' : '<p>Bitte Famio im Browser oder in der App öffnen und unter Einstellungen → Mein Konto löschen fortfahren.</p>'}
<p>Zur Bestätigung brauchst du dein Passwort und, falls aktiviert, deinen Zwei-Faktor-Code. Als letzter Administrator musst du die Verwaltung zuerst an ein anderes Mitglied übertragen.</p>
</body></html>''';
