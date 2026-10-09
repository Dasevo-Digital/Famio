import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import 'form_dialog.dart';
import 'password_reveal.dart';
import '../l10n.dart';

/// Asks for the password, fetches the export (own data or, with [family],
/// the whole family) and lets the member save the ZIP.
Future<void> exportData(BuildContext context, {bool family = false}) async {
  final api = AppScope.read(context).engine!.api;
  final messenger = ScaffoldMessenger.of(context);
  final password = TextEditingController();
  List<int>? zip;
  await showDialog<void>(
    context: context,
    builder: (context) => FormDialog(
      title: family ? tr.adminExportFamily : tr.settingsExport,
      submitLabel: tr.adminExport,
      controllers: [password],
      fields: [
        Text(
          family ? tr.exportZipFileAllFamily : tr.exportZipFileEverythingYou,
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
        zip = await api.exportData(password: password.text, family: family);
      },
    ),
  );
  final bytes = zip;
  if (bytes == null) return;
  final day = DateTime.now().toIso8601String().substring(0, 10);
  final saved = await FilePicker.saveFile(
    dialogTitle: tr.exportSaveExport,
    fileName: family ? 'famio-familie-$day.zip' : 'famio-meine-daten-$day.zip',
    bytes: Uint8List.fromList(bytes),
    mimeType: 'application/zip',
  );
  messenger.showSnackBar(
    SnackBar(
      content: Text(saved == null ? tr.exportNotSaved : tr.exportExportSaved),
    ),
  );
}
