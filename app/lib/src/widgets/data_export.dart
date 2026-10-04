import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import 'form_dialog.dart';
import 'password_reveal.dart';

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
      title: family ? 'Familie exportieren' : 'Meine Daten exportieren',
      submitLabel: 'Exportieren',
      controllers: [password],
      fields: [
        Text(
          family
              ? 'Eine ZIP-Datei mit allen Daten der Familie: Bereiche als '
                    'JSON, hochgeladene Dateien, Mitglieder (ohne Passwörter) '
                    'und Einstellungen. Standortverläufe sind nicht dabei. '
                    'Bewahre sie sicher auf, sie ist nicht verschlüsselt.'
              : 'Eine ZIP-Datei mit allem, was du in Famio sehen kannst, '
                    'deinen Dateien und deinem Standortverlauf. Bewahre sie '
                    'sicher auf, sie ist nicht verschlüsselt.',
        ),
        const SizedBox(height: 12),
        PasswordReveal(
          builder: (_, obscure, toggle) => TextField(
            controller: password,
            obscureText: obscure,
            autofocus: true,
            contextMenuBuilder: PasswordReveal.contextMenu,
            decoration: InputDecoration(
              labelText: 'Dein Famio-Passwort',
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
    dialogTitle: 'Export sichern',
    fileName: family ? 'famio-familie-$day.zip' : 'famio-meine-daten-$day.zip',
    bytes: Uint8List.fromList(bytes),
    mimeType: 'application/zip',
  );
  messenger.showSnackBar(
    SnackBar(
      content: Text(saved == null ? 'Nicht gesichert' : 'Export gesichert'),
    ),
  );
}
