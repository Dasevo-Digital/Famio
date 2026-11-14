import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';
import '../location/location_sharing.dart';
import '../security/app_lock.dart';

/// A photo from the camera, or null. When iOS or Android refuse the camera,
/// it says how to allow it instead of doing nothing (#498).
Future<XFile?> takePhoto(
  BuildContext context, {
  double? maxWidth,
  int? imageQuality,
  ImagePicker? picker,
}) async {
  try {
    return await AppLock.picking(
      () => (picker ?? ImagePicker()).pickImage(
        source: ImageSource.camera,
        maxWidth: maxWidth,
        imageQuality: imageQuality,
      ),
    );
  } on PlatformException catch (e) {
    if (!cameraRefused(e)) rethrow;
    if (context.mounted) await showCameraRefused(context);
    return null;
  }
}

/// Whether the camera's error means that Famio may not use it.
bool cameraRefused(PlatformException e) =>
    e.code == 'camera_access_denied' || e.code == 'camera_access_restricted';

/// Tells that Famio may not use the camera, with a way to its settings.
Future<void> showCameraRefused(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(tr.cameraDeniedTitle),
    content: Text(tr.cameraDeniedText),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr.commonClose),
      ),
      FilledButton(
        onPressed: () {
          Navigator.pop(context);
          if (LocationSharing.supported) {
            LocationSharing.openAppSettings();
          } else if (!kIsWeb) {
            launchUrl(Uri.parse('app-settings:'));
          }
        },
        child: Text(tr.commonOpenSettings),
      ),
    ],
  ),
);
