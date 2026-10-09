import 'package:flutter/material.dart';

import '../design/app_icons.dart';
import '../design/palette.dart';
import '../l10n.dart';

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
      title: Text(tr.trustCheckServerSCertificate),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.trustServerEncryptsConnectionIts),
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
            Text(tr.trustIfDoesNotMatch, style: TextStyle(color: c.inkSoft)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(tr.trustMatches),
        ),
      ],
    ),
  );
  return ok ?? false;
}
