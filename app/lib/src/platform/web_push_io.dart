/// A browser's push subscription (see web_push_web.dart).
typedef BrowserSubscription = ({String endpoint, String p256dh, String auth});

/// The installed apps have their own push; only the web app uses this.
bool get webPushSupported => false;

bool get webPushBlocked => false;

bool get webPushNeedsHomeScreen => false;

String get browserName => '';

Future<BrowserSubscription?> currentWebPush() async => null;

Future<BrowserSubscription?> startWebPush(
  Future<String> Function() publicKey,
) async => null;

Future<String?> stopWebPush() async => null;

/// What a tapped browser notification asks to open (#385): none here.
String? takeWebOpenRequest() => null;

/// Same, while the web app runs: none here.
Stream<String> get webOpenRequests => const Stream.empty();
