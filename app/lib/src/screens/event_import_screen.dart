import 'dart:convert';
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
import '../platform/document_scanner.dart';
import '../widgets/files.dart';
import 'event_editor.dart';
import 'ics_import_screen.dart';

/// Appointments from a photo of a letter, an invitation or pasted text:
/// recognised on the device, checked by hand, then added. Calendar files
/// (`.ics`) are read by the family's server and taken over completely,
/// series included.
class EventImportScreen extends StatefulWidget {
  const EventImportScreen({super.key, @visibleForTesting this.debugPhoto});

  /// Starts with this picture, as if it had just been chosen.
  final String? debugPhoto;

  @override
  State<EventImportScreen> createState() => _EventImportScreenState();
}

/// The photo or PDF the text was read from. It stays with the appointments:
/// recognition makes mistakes, the original shows what the letter said.
class _Source {
  const _Source(
    this.path,
    this.name, {
    this.pdf = false,
    this.mime,
    this.temporary = false,
  });

  final String path;
  final String name;
  final bool pdf;
  final String? mime;

  /// A copy of our own, deleted with the screen.
  final bool temporary;

  void delete() {
    if (temporary) File(path).delete().ignore();
  }
}

class _EventImportScreenState extends State<EventImportScreen> {
  final _text = TextEditingController();
  List<EventSuggestion>? _found;
  final _chosen = <int>{};
  final _titles = <int, TextEditingController>{};

  /// Suggestions already taken over through the editor.
  final _saved = <int>{};
  var _busy = false;
  String? _message;

  _Source? _source;
  var _keepSource = true;

  /// One upload, however many appointments carry the original.
  Future<FileRef>? _upload;
  var _notKept = false;

  static bool get _camera => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    final photo = widget.debugPhoto;
    if (photo != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _recognise(_Source(photo, photo.split('/').last)),
      );
    }
  }

  @override
  void dispose() {
    _text.dispose();
    for (final c in _titles.values) {
      c.dispose();
    }
    _source?.delete();
    super.dispose();
  }

  /// A copy for recognition of a file that has no path (e.g. in a cloud).
  static Future<String> _copy(PlatformFile file, String ending) async {
    final tmp = File(
      '${Directory.systemTemp.path}/famio-import-'
      '${DateTime.now().millisecondsSinceEpoch}$ending',
    );
    await tmp.writeAsBytes(await file.readAsBytes());
    return tmp.path;
  }

  Future<void> _pdf() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (picked.isEmpty) return;
    final file = picked.first;
    await _recognise(
      _Source(
        file.path ?? await _copy(file, '.pdf'),
        file.name,
        pdf: true,
        mime: 'application/pdf',
        temporary: file.path == null,
      ),
    );
  }

  Future<void> _photo({required bool camera}) async {
    if (camera) {
      final shot = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 3000,
      );
      if (shot == null) return;
      await _recognise(_Source(shot.path, shot.name, mime: 'image/jpeg'));
      return;
    }
    final picked = await FilePicker.pickFiles(type: FileType.image);
    if (picked.isEmpty) return;
    final file = picked.first;
    await _recognise(
      _Source(
        file.path ?? await _copy(file, ''),
        file.name,
        temporary: file.path == null,
      ),
    );
  }

  /// The scanner straightens the page and evens out the light, which reads
  /// far better than a photo at an angle.
  Future<void> _scan() async {
    final scan = await scanPicked(context);
    if (scan == null) return;
    final tmp = File(
      '${Directory.systemTemp.path}/famio-import-'
      '${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await tmp.writeAsBytes(scan.bytes!);
    await _recognise(
      _Source(
        tmp.path,
        scan.name,
        pdf: true,
        mime: 'application/pdf',
        temporary: true,
      ),
    );
  }

  void _use(_Source? source) {
    _source?.delete();
    _source = source;
    _upload = null;
    _keepSource = true;
  }

  Future<void> _recognise(_Source source) async {
    if (!mounted) return source.delete();
    _use(source);
    setState(() {
      _busy = true;
      _message = null;
    });
    final text = await _read(
      () => source.pdf ? Ocr.pdfText(source.path) : Ocr.recognize(source.path),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (text == null) {
      setState(
        () => _message ??= source.pdf
            ? tr.importNoTextWasFound
            : tr.importNoTextWasRecognized,
      );
      return;
    }
    _text.text = text;
    _analyse();
  }

  /// Runs the recognition; a model Google Play has not loaded yet becomes
  /// the message instead of "no text".
  Future<String?> _read(Future<String?> Function() recognize) async {
    try {
      return await recognize();
    } on OcrModelMissing catch (e) {
      _message = e.loading ? tr.ocrModelLoading : tr.ocrNeedsPlayServices;
      return null;
    }
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
    // The date of the letter and what is over already stay unticked.
    final now = DateTime.now();
    setState(() {
      _found = found;
      _saved.clear();
      _chosen
        ..clear()
        ..addAll([
          for (final (i, e) in found.indexed)
            if (e.end.isAfter(now)) i,
        ]);
      _message = found.isEmpty ? tr.importNoEventsFoundText : null;
    });
  }

  /// The original as an attachment; empty if it is not wanted or cannot be
  /// stored right now. The appointments matter more: they stay, and
  /// [_finish] says that the original is missing.
  Future<List<FileRef>> _attachment() async {
    final source = _source;
    if (source == null || !_keepSource) return const [];
    final state = AppScope.read(context);
    final file = File(source.path);
    try {
      final ref = await (_upload ??= pickedFromSource(
        name: source.name,
        path: source.path,
        mime: source.mime,
        length: file.length,
        openRead: file.openRead,
        maxBytes: uploadLimit(state.engine!),
      ).then((picked) => uploadPickedState(state, picked)));
      return [ref];
    } on ApiError {
      _upload = null;
    } on FileSystemException {
      _upload = null;
    }
    _notKept = true;
    return const [];
  }

  /// The whole event form, filled in: saved from there, the suggestion is
  /// done.
  Future<void> _edit(int i) async {
    final e = _found![i];
    final title = _titles[i]!.text.trim();
    setState(() => _busy = true);
    final files = await _attachment();
    if (!mounted) return;
    setState(() => _busy = false);
    final saved = await showEventEditor(
      context,
      start: e.start,
      end: e.end,
      allDay: e.allDay,
      title: title.isEmpty ? e.title : title,
      location: e.location,
      notes: tr.importTakenLine(e.line),
      files: files,
    );
    if (!saved || !mounted) return;
    setState(() {
      _saved.add(i);
      _chosen.remove(i);
    });
    if (_saved.length == _found!.length) {
      _finish(_saved.length);
    } else {
      _tell(tr.import1EventAdded);
    }
  }

  void _tell(String added) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_notKept ? '$added ${tr.importOriginalNotKept}' : added),
      ),
    );
  }

  void _finish(int added) {
    _tell(added == 1 ? tr.import1EventAdded : tr.importCountEventsAdded(added));
    Navigator.pop(context);
  }

  Future<void> _icsFile() async {
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['ics', 'ical', 'icalendar', 'ifb'],
      );
    } on Exception {
      // Some systems know no calendar file type: any file then.
      picked = await FilePicker.pickFiles();
    }
    if (picked.isEmpty || !mounted) return;
    final file = picked.first;
    final api = AppScope.engineOf(context).api;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length > 10 * 1024 * 1024) {
        setState(() => _message = tr.importIcsTooLarge);
        return;
      }
      final preview = await api.readIcsFile(
        utf8.decode(bytes, allowMalformed: true),
      );
      if (!mounted) return;
      setState(() => _busy = false);
      final added = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => IcsImportScreen(preview: preview)),
      );
      if (added == true && mounted) Navigator.pop(context);
    } on ApiError catch (e) {
      if (mounted) setState(() => _message = e.message);
    } catch (e) {
      if (mounted) setState(() => _message = tr.importIcsFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final engine = AppScope.engineOf(context);
    final found = _found!;
    setState(() => _busy = true);
    final files = await _attachment();
    if (!mounted) return;
    setState(() => _busy = false);
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
          location: e.location,
          notes: tr.importTakenLine(e.line),
          files: files,
        ),
      );
      added++;
    }
    _finish(added + _saved.length);
  }

  void _showSource(String path) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InteractiveViewer(
                maxScale: 6,
                child: Image.file(File(path)),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr.commonClose),
            ),
          ],
        ),
      ),
    );
  }

  /// What the suggestions were read from, to compare them with it.
  Widget _sourceCard(_Source source) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: SoftCard(
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: MergeSemantics(
              child: Row(
                children: [
                  Checkbox(
                    value: _keepSource,
                    onChanged: (v) => setState(() => _keepSource = v ?? false),
                  ),
                  Expanded(child: Text(tr.importKeepOriginal)),
                ],
              ),
            ),
          ),
          if (source.pdf)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(AppIcons.fileText),
            )
          else
            Semantics(
              button: true,
              label: tr.importShowOriginal,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _showSource(source.path),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.file(
                    File(source.path),
                    width: 72,
                    height: 72,
                    cacheWidth: 216,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.square(
                      dimension: 72,
                      child: Icon(AppIcons.imageBroken),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  static String _when(EventSuggestion e) {
    final day = DateFormat.yMMMEd(appLanguage);
    if (!e.allDay) {
      return tr.importDay(
        day.format(e.start),
        DateFormat.jm(appLanguage).format(e.start),
        DateFormat.jm(appLanguage).format(e.end),
      );
    }
    final last = DateUtils.addDaysToDate(e.end, -1);
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
                if (Ocr.available && canScanDocuments)
                  OutlinedButton.icon(
                    icon: const Icon(AppIcons.scanText),
                    label: Text(tr.filesScanDocument),
                    onPressed: _busy ? null : _scan,
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
                  icon: const Icon(AppIcons.calendarBlank),
                  label: Text(tr.importIcsFile),
                  onPressed: _busy ? null : _icsFile,
                ),
                OutlinedButton.icon(
                  icon: const Icon(AppIcons.clipboardList),
                  label: Text(tr.importClipboard),
                  onPressed: _busy
                      ? null
                      : () async {
                          final data = await Clipboard.getData('text/plain');
                          if (data?.text != null) {
                            _use(null);
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
            if (_source != null) _sourceCard(_source!),
            for (final (i, e) in found.indexed)
              if (!_saved.contains(i))
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
                            () =>
                                v ?? false ? _chosen.add(i) : _chosen.remove(i),
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
                              if (e.location.isNotEmpty)
                                Text(
                                  e.location,
                                  style: theme.textTheme.bodyMedium,
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
                        IconButton(
                          icon: const Icon(AppIcons.pencilSimple),
                          tooltip: tr.importEditEvent,
                          onPressed: _busy ? null : () => _edit(i),
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
                  onPressed: _chosen.isEmpty || _busy ? null : _add,
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
