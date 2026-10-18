import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Whether this browser can use passkeys here (WebAuthn needs HTTPS or
/// localhost).
bool get passkeysSupported =>
    web.window.isSecureContext && globalContext.has('PublicKeyCredential');

/// Lets the device create a passkey for [options] (from the server, JSON
/// with base64url fields); null if the user cancelled.
Future<Map<String, Object?>?> createPasskey(
  Map<String, Object?> options,
) async {
  final publicKey = options.jsify()! as JSObject;
  _bytesAt(publicKey, 'challenge');
  _bytesAt(publicKey.getProperty<JSObject>('user'.toJS), 'id');
  for (final item
      in publicKey
          .getProperty<JSArray<JSObject>>('excludeCredentials'.toJS)
          .toDart) {
    _bytesAt(item, 'id');
  }
  final web.Credential? created;
  try {
    created = await web.window.navigator.credentials
        .create(
          web.CredentialCreationOptions(
            publicKey: publicKey as web.PublicKeyCredentialCreationOptions,
          ),
        )
        .toDart;
  } catch (e) {
    if (_cancelled(e)) return null;
    rethrow;
  }
  if (created == null) return null;
  final credential = created as web.PublicKeyCredential;
  final response = credential.response as web.AuthenticatorAttestationResponse;
  return {
    'id': credential.id,
    'rawId': _b64(credential.rawId),
    'type': 'public-key',
    'response': {
      'clientDataJSON': _b64(response.clientDataJSON),
      'attestationObject': _b64(response.attestationObject),
    },
  };
}

/// Signs [options]' challenge with one of the device's passkeys for this
/// site; null if the user cancelled.
Future<Map<String, Object?>?> usePasskey(Map<String, Object?> options) async {
  final publicKey = options.jsify()! as JSObject;
  _bytesAt(publicKey, 'challenge');
  final web.Credential? found;
  try {
    found = await web.window.navigator.credentials
        .get(
          web.CredentialRequestOptions(
            publicKey: publicKey as web.PublicKeyCredentialRequestOptions,
          ),
        )
        .toDart;
  } catch (e) {
    if (_cancelled(e)) return null;
    rethrow;
  }
  if (found == null) return null;
  final credential = found as web.PublicKeyCredential;
  final response = credential.response as web.AuthenticatorAssertionResponse;
  return {
    'id': credential.id,
    'rawId': _b64(credential.rawId),
    'type': 'public-key',
    'response': {
      'clientDataJSON': _b64(response.clientDataJSON),
      'authenticatorData': _b64(response.authenticatorData),
      'signature': _b64(response.signature),
      if (response.userHandle case final handle?) 'userHandle': _b64(handle),
    },
  };
}

/// The browser reports "cancelled", "timed out" and "no passkey here"
/// alike, as NotAllowedError (a DOMException; its text names it).
bool _cancelled(Object error) {
  final text = error.toString();
  return text.contains('NotAllowedError') || text.contains('AbortError');
}

/// Replaces the base64url text at [key] with its bytes.
void _bytesAt(JSObject object, String key) {
  final text = object.getProperty<JSString>(key.toJS).toDart;
  final bytes = base64Url.decode(
    text.padRight((text.length + 3) ~/ 4 * 4, '='),
  );
  object.setProperty(key.toJS, Uint8List.fromList(bytes).toJS);
}

String _b64(JSArrayBuffer buffer) =>
    base64Url.encode(buffer.toDart.asUint8List()).replaceAll('=', '');
