import 'package:flutter/material.dart';

import '../design/app_icons.dart';
import '../design/palette.dart';

/// Asks whether to trust the server's own certificate, showing its
/// fingerprint to compare with the server log or Server-Verwaltung.
Future<bool> confirmCertificate(
  BuildContext context,
  String fingerprint,
) async {
  final c = FamioColors.of(context);
  final groups = fingerprint.split(':');
  // Four lines of eight bytes are easier to compare than one long line.
  final lines = [
    for (var i = 0; i < groups.length; i += 8) groups.skip(i).take(8).join(':'),
  ];
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      // Fits small phones with the keyboard still open.
      scrollable: true,
      icon: Icon(AppIcons.shield, color: c.strong(FamioSection.settings)),
      title: const Text('Zertifikat des Servers prüfen'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Der Server verschlüsselt die Verbindung mit einem eigenen '
              'Zertifikat. Vergleiche den Fingerabdruck einmalig mit dem '
              'im Server-Log (z. B. „docker logs famio“) oder unter '
              'Einstellungen → Server-Verwaltung → Status auf einem '
              'anderen Gerät:',
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.surfaceSoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                lines.join('\n'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Stimmt er nicht überein, abbrechen – dann könnte jemand die '
              'Verbindung abfangen.',
              style: TextStyle(color: c.inkSoft),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Stimmt überein'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
