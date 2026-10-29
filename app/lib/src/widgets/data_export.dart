import 'dart:io';
import 'package:famio_client/famio_client.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'form_dialog.dart';
import 'password_reveal.dart';
import '../platform/export_file.dart';
import '../l10n.dart';

/// Asks for the password, fetches the export (own data or, with [family],
/// the whole family) and lets the member save the ZIP.
Future<void> exportData(BuildContext context, {bool family = false}) async {
  final state = AppScope.read(context);
  final api = state.engine!.api;
  final messenger = ScaffoldMessenger.of(context);
  final password = TextEditingController();
  var cancellation = TransferCancellation();
  final progress = ValueNotifier<(int, int?)>((0, null));
  var saved = false;
  final day = DateTime.now().toIso8601String().substring(0, 10);
  await showDialog<void>(
    context: context,
    builder: (context) => FormDialog(
      title: family ? tr.adminExportFamily : tr.settingsExport,
      submitLabel: tr.adminExport,
      controllers: [password],
      onCancel: () => cancellation.cancel(),
      fields: [
        Text(
          family ? tr.exportZipFileAllFamily : tr.exportZipFileEverythingYou,
        ),
        if (kIsWeb) Text(tr.exportBrowserLimit),
        ValueListenableBuilder<(int, int?)>(
          valueListenable: progress,
          builder: (_, value, _) => value.$1 == 0
              ? const SizedBox.shrink()
              : LinearProgressIndicator(
                  value: value.$2 == null ? null : value.$1 / value.$2!,
                ),
        ),
        const SizedBox(height: 12),
        PasswordReveal(
          builder: (_, obscure, toggle) => TextField(
            controller: password,
            obscureText: obscure,
            autofocus: true,
            contextMenuBuilder: PasswordReveal.contextMenu,
            decoration: InputDecoration(
              labelText: tr.exportFamioPassword,
              suffixIcon: toggle,
            ),
          ),
        ),
      ],
      onSubmit: () async {
        final transferCancellation = cancellation = TransferCancellation();
        progress.value = (0, null);
        final box = context.findRenderObject() as RenderBox?;
        try {
          saved = await saveExport(
            api: api,
            password: password.text,
            family: family,
            tempDir: state.files!.tempDir,
            fileName: family
                ? 'famio-familie-$day.zip'
                : 'famio-meine-daten-$day.zip',
            dialogTitle: tr.exportSaveExport,
            cancellation: transferCancellation,
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
            onProgress: (received, total) {
              if (!transferCancellation.cancelled) {
                progress.value = (received, total);
              }
            },
          );
        } on PlatformException {
          transferCancellation.cancel();
          throw ApiError(0, 'save_failed', tr.exportSaveFailed);
        } on FileSystemException {
          transferCancellation.cancel();
          throw ApiError(0, 'save_failed', tr.exportSaveFailed);
        }
      },
    ),
  );
  cancellation.cancel();
  // A cancelled transfer may finish cleanup after the route has closed.
  // Its progress callback checks cancellation before touching this notifier.
  progress.dispose();
  if (!saved) return;
  messenger.showSnackBar(SnackBar(content: Text(tr.exportExportSaved)));
}
