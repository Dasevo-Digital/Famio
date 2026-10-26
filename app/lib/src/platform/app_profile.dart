import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// When iOS stops opening this app: a build installed from a Mac carries a
/// provisioning profile that ends (a week after installing with a free
/// developer account). Null on other systems and for App Store builds.
Future<DateTime?> appProfileExpires() async {
  if (kIsWeb || !Platform.isIOS) return null;
  try {
    final end = await const MethodChannel(
      'famio/profile',
    ).invokeMethod<String>('expires');
    return end == null ? null : DateTime.tryParse(end)?.toLocal();
  } catch (_) {
    return null;
  }
}

/// Warn this long before [appProfileExpires].
const profileWarning = Duration(days: 3);
