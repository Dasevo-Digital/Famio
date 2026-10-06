import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/event_extract.dart';
import '../data/family_data.dart';
import '../data/ocr.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';

/// Appointments from a photo of a letter, an invitation or pasted text:
/// recognised on the device, checked by hand, then added.
class EventImportScreen extends StatefulWidget {
  const EventImportScreen({super.key});

  @override
  State<EventImportScreen> createState() => _EventImportScreenState();
}

class _EventImportScreenState extends State<EventImportScreen> {
  final _text = TextEditingController();
  List<EventSuggestion>? _found;
  final _chosen = <int>{};
  final _titles = <int, TextEditingController>{};
  var _busy = false;
  String? _message;

  static bool get _camera => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void dispose() {
    _text.dispose();
    for (final c in _titles.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _photo({required bool camera}) async {
    String? path;
    if (camera) {
      final shot = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 3000,
      );
      path = shot?.path;
    } else {
      final picked = await FilePicker.pickFiles(type: FileType.image);
      if (picked.isEmpty) return;
      final file = picked.first;
      path = file.path;
      if (path == null) {
        // No path (e.g. a cloud file): a temporary copy for recognition.
        final tmp = File(
          '${Directory.systemTemp.path}/famio-ocr-${DateTime.now().millisecondsSinceEpoch}',
        );
        await tmp.writeAsBytes(await file.readAsBytes());
        path = tmp.path;
      }
    }
    if (path == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final text = await Ocr.recognize(path);
    if (!mounted) return;
    setState(() => _busy = false);
    if (text == null) {
      setState(() => _message = 'Auf dem Bild wurde kein Text erkannt.');
      return;
    }
    _text.text = text;
    _analyse();
  }

  void _analyse() {
    final found = extractEvents(_text.text);
    for (final c in _titles.values) {
      c.dispose();
    }
    _titles
      ..clear()
      ..addAll({
        for (final (i, e) in found.indexed)
          i: TextEditingController(text: e.title),
      });
    setState(() {
      _found = found;
      _chosen
        ..clear()
        ..addAll(List.generate(found.length, (i) => i));
      _message = found.isEmpty ? 'Keine Termine im Text gefunden.' : null;
    });
  }

  void _add() {
    final engine = AppScope.engineOf(context);
    final found = _found!;
    var added = 0;
    for (final i in _chosen) {
      final e = found[i];
      engine.saveEvent(
        CalendarEvent(
          id: newId(),
          title: _titles[i]!.text.trim().isEmpty
              ? e.title
              : _titles[i]!.text.trim(),
          start: e.start,
          end: e.end,
          allDay: e.allDay,
          notes: 'Übernommen aus: ${e.line}',
        ),
      );
      added++;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 1 ? '1 Termin eingetragen' : '$added Termine eingetragen',
        ),
      ),
    );
    Navigator.pop(context);
  }

  static String _when(EventSuggestion e) {
    final day = DateFormat('E, d. MMM y', 'de');
    if (!e.allDay) {
      return '${day.format(e.start)}, ${DateFormat.Hm('de').format(e.start)}'
          '–${DateFormat.Hm('de').format(e.end)} Uhr';
    }
    final last = e.end.subtract(const Duration(days: 1));
    return DateUtils.isSameDay(e.start, last)
        ? '${day.format(e.start)}, ganztägig'
        : '${day.format(e.start)} – ${day.format(last)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = FamioColors.of(context).strong(FamioSection.calendar);
    final found = _found;
    return SectionPage(
      section: FamioSection.calendar,
      title: 'Termine erkennen',
      subtitle: 'Aus Elternbrief, Einladung oder Mail',
      maxBodyWidth: 720,
      body: ListView(
        padding: EdgeInsets.only(bottom: listBottomPadding(context)),
        children: [
          if (found == null) ...[
            const SoftCard(
              child: Text(
                'Famio liest Daten und Uhrzeiten aus dem Text und schlägt '
                'Termine vor. Die Erkennung läuft auf diesem Gerät; nichts '
                'wird hochgeladen. Prüfe die Vorschläge vor dem Übernehmen.',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (Ocr.available && _camera)
                  FilledButton.icon(
                    icon: const Icon(AppIcons.camera),
                    label: const Text('Foto aufnehmen'),
                    onPressed: _busy ? null : () => _photo(camera: true),
                  ),
                if (Ocr.available)
                  OutlinedButton.icon(
                    icon: const Icon(AppIcons.image),
                    label: const Text('Bild wählen'),
                    onPressed: _busy ? null : () => _photo(camera: false),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(AppIcons.clipboardList),
                  label: const Text('Aus der Zwischenablage'),
                  onPressed: _busy
                      ? null
                      : () async {
                          final data = await Clipboard.getData('text/plain');
                          if (data?.text != null) {
                            _text.text = data!.text!;
                            _analyse();
                          }
                        },
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              minLines: 4,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: 'Oder Text hier einfügen',
                hintText: 'z. B. „Elternabend am 16.10. um 19 Uhr“',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _busy ? null : _analyse,
                child: const Text('Termine suchen'),
              ),
            ),
          ] else ...[
            for (final (i, e) in found.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SoftCard(
                  padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Checkbox(
                        value: _chosen.contains(i),
                        onChanged: (v) => setState(
                          () => v ?? false ? _chosen.add(i) : _chosen.remove(i),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: _titles[i],
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText: 'Titel',
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _when(e),
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: accent,
                              ),
                            ),
                            Text(
                              e.line,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() => _found = null),
                  child: const Text('Zurück'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _chosen.isEmpty ? null : _add,
                  child: Text(
                    _chosen.length == 1
                        ? '1 Termin übernehmen'
                        : '${_chosen.length} Termine übernehmen',
                  ),
                ),
              ],
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
