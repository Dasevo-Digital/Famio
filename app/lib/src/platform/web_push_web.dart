import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// A browser's push subscription: the address at its push service and the
/// keys the server encrypts for (RFC 8291).
typedef BrowserSubscription = ({String endpoint, String p256dh, String auth});

/// Whether this browser can receive push messages (HTTPS, a service
/// worker and the Push API; on iPhones only in the home screen app).
bool get webPushSupported =>
    web.window.isSecureContext &&
    web.window.navigator.has('serviceWorker') &&
    globalContext.has('PushManager') &&
    globalContext.has('Notification');

/// Notifications are blocked for this site in the browser's settings.
bool get webPushBlocked =>
    webPushSupported && web.Notification.permission == 'denied';

/// iPhone or iPad in Safari: push only works after "Zum Home-Bildschirm".
bool get webPushNeedsHomeScreen {
  final agent = web.window.navigator.userAgent;
  final ios =
      agent.contains('iPhone') ||
      agent.contains('iPad') ||
      agent.contains('Macintosh') && web.window.navigator.maxTouchPoints > 1;
  final standalone = web.window
      .matchMedia('(display-mode: standalone)')
      .matches;
  return ios && !standalone && !webPushSupported;
}

/// "Firefox · Windows", shown in the server's list of devices.
String get browserName {
  final agent = web.window.navigator.userAgent;
  final browser = switch (agent) {
    _ when agent.contains('Edg/') => 'Edge',
    _ when agent.contains('Firefox/') => 'Firefox',
    _ when agent.contains('OPR/') => 'Opera',
    _ when agent.contains('Chrome/') => 'Chrome',
    _ when agent.contains('Safari/') => 'Safari',
    _ => 'Browser',
  };
  final system = switch (agent) {
    _ when agent.contains('iPhone') => 'iPhone',
    _ when agent.contains('iPad') => 'iPad',
    _ when agent.contains('Android') => 'Android',
    _ when agent.contains('Windows') => 'Windows',
    _ when agent.contains('Mac OS') => 'macOS',
    _ when agent.contains('Linux') => 'Linux',
    _ => '',
  };
  return system.isEmpty ? browser : '$browser · $system';
}

/// The subscription this browser already has for Famio, if any.
Future<BrowserSubscription?> currentWebPush() async {
  if (!webPushSupported || web.Notification.permission != 'granted') {
    return null;
  }
  final registration = await web.window.navigator.serviceWorker
      .getRegistration()
      .toDart;
  final subscription = await registration?.pushManager.getSubscription().toDart;
  return subscription == null ? null : _read(subscription);
}

/// Asks for permission (call it right from a tap: Safari insists, so
/// nothing may be awaited before), registers the service worker and
/// subscribes with the server's [publicKey]. Null if refused.
Future<BrowserSubscription?> startWebPush(
  Future<String> Function() publicKey,
) async {
  final answer = web.Notification.requestPermission().toDart;
  if ((await answer).toDart != 'granted') return null;
  final container = web.window.navigator.serviceWorker;
  await container
      .register('famio_push.js'.toJS, web.RegistrationOptions(scope: './'))
      .toDart;
  final registration = await container.ready.toDart;
  final text = await publicKey();
  final key = base64Url.decode(text.padRight((text.length + 3) ~/ 4 * 4, '='));
  var existing = await registration.pushManager.getSubscription().toDart;
  // Made for another server key (a new server at this address): renew.
  final oldKey = existing?.options.applicationServerKey?.toDart.asUint8List();
  if (existing != null && (oldKey == null || !_same(oldKey, key))) {
    await existing.unsubscribe().toDart;
    existing = null;
  }
  final subscription =
      existing ??
      await registration.pushManager
          .subscribe(
            web.PushSubscriptionOptionsInit(
              userVisibleOnly: true,
              applicationServerKey: key.toJS,
            ),
          )
          .toDart;
  return _read(subscription);
}

/// Ends this browser's subscription; returns its address for the server.
Future<String?> stopWebPush() async {
  if (!webPushSupported) return null;
  final registration = await web.window.navigator.serviceWorker
      .getRegistration()
      .toDart;
  final subscription = await registration?.pushManager.getSubscription().toDart;
  if (subscription == null) return null;
  await subscription.unsubscribe().toDart;
  return subscription.endpoint;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

BrowserSubscription _read(web.PushSubscription s) {
  String key(String name) {
    final buffer = s.getKey(name);
    if (buffer == null) return '';
    return base64Url.encode(buffer.toDart.asUint8List()).replaceAll('=', '');
  }

  return (endpoint: s.endpoint, p256dh: key('p256dh'), auth: key('auth'));
}
