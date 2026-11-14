import 'dart:async';

import 'package:famio/src/widgets/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

class _Refusing extends ImagePicker {
  _Refusing(this.code);

  final String code;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) => throw PlatformException(code: code);
}

/// A refused camera says how to allow it instead of doing nothing (#498).
void main() {
  Future<BuildContext> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Builder(builder: (c) => Text('x'))),
      ),
    );
    return tester.element(find.text('x'));
  }

  testWidgets('refused: a hint with the way to the settings', (tester) async {
    final context = await open(tester);
    XFile? photo = XFile('nicht');
    unawaited(
      takePhoto(
        context,
        picker: _Refusing('camera_access_denied'),
      ).then((p) => photo = p),
    );
    await tester.pumpAndSettle();
    expect(find.text('Kein Zugriff auf die Kamera'), findsOneWidget);
    expect(find.text('Einstellungen öffnen'), findsOneWidget);
    await tester.tap(find.text('Schließen'));
    await tester.pumpAndSettle();
    expect(photo, isNull);
  });

  testWidgets('other camera errors stay errors', (tester) async {
    final context = await open(tester);
    await expectLater(
      takePhoto(context, picker: _Refusing('no_available_camera')),
      throwsA(isA<PlatformException>()),
    );
  });
}
