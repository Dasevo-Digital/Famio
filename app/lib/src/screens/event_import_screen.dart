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
import '../l10n.dart';

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

  Future<void> _pdf() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (picked.isEmpty) return;
    final file = picked.first;
    var path = file.path;
    if (path == null) {
      final tmp = File(
        '${Directory.systemTemp.path}/famio-pdf-${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      await tmp.writeAsBytes(await file.readAsBytes());
      path = tmp.path;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final text = await Ocr.pdfText(path);
    if (!mounted) return;
    setState(() => _busy = false);
    if (text == null) {
      setState(() => _message = tr.importNoTextWasFound);
      return;
    }
    _text.text = text;
    _analyse();
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
      setState(() => _message = tr.importNoTextWasRecognized);
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
      _message = found.isEmpty ? tr.importNoEventsFoundText : null;
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
          notes: tr.importTakenLine(e.line),
        ),
      );
      added++;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 1 ? tr.import1EventAdded : tr.importCountEventsAdded(added),
        ),
      ),
    );
    Navigator.pop(context);
  }

  static String _when(EventSuggestion e) {
    final day = DateFormat.yMMMEd(appLanguage);
    if (!e.allDay) {
      return tr.importDay(
        day.format(e.start),
        DateFormat.jm(appLanguage).format(e.start),
        DateFormat.jm(appLanguage).format(e.end),
      );
    }
    final last = e.end.subtract(const Duration(days: 1));
    return DateUtils.isSameDay(e.start, last)
        ? tr.importDayAllDay(day.format(e.start))
        : '${day.format(e.start)} – ${day.format(last)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = FamioColors.of(context).strong(FamioSection.calendar);
    final found = _found;
    return SectionPage(
      section: FamioSection.calendar,
      title: tr.importRecognizeEvents,
      subtitle: tr.importParentsLetterInvitationEmail,
      maxBodyWidth: 720,
      body: ListView(
        padding: EdgeInsets.only(bottom: listBottomPadding(context)),
        children: [
          if (found == null) ...[
            SoftCard(child: Text(tr.importFamioReadsDatesTimes)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (Ocr.available && _camera)
                  FilledButton.icon(
                    icon: const Icon(AppIcons.camera),
                    label: Text(tr.importTakePhoto),
                    onPressed: _busy ? null : () => _photo(camera: true),
                  ),
                if (Ocr.available)
                  OutlinedButton.icon(
                    icon: const Icon(AppIcons.image),
                    label: Text(tr.importChoosePicture),
                    onPressed: _busy ? null : () => _photo(camera: false),
                  ),
                if (Ocr.available)
                  OutlinedButton.icon(
                    icon: const Icon(AppIcons.fileText),
                    label: Text(tr.importChoosePdf),
                    onPressed: _busy ? null : _pdf,
                  ),
                OutlinedButton.icon(
                  icon: const Icon(AppIcons.clipboardList),
                  label: Text(tr.importClipboard),
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
              decoration: InputDecoration(
                labelText: tr.importPasteTextHere,
                hintText: tr.importEGParentsEvening,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _busy ? null : _analyse,
                child: Text(tr.importFindEvents),
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
                              decoration: InputDecoration(
                                isDense: true,
                                labelText: tr.commonTitle,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _when(e),
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: FamioColors.of(context).text(accent),
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
                  child: Text(tr.commonBack),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _chosen.isEmpty ? null : _add,
                  child: Text(
                    _chosen.length == 1
                        ? tr.importTakeOver1Event
                        : tr.importTakeOverCountEvents(_chosen.length),
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
