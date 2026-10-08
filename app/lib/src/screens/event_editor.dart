import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../format.dart';
import '../widgets/event_comments.dart';
import '../widgets/member_avatar.dart';
import '../widgets/undo_delete.dart';

/// Opens the editor for a new event on [day], or for an existing
/// [occurrence] (which may be one appearance of a series).
Future<void> showEventEditor(
  BuildContext context, {
  DateTime? day,
  Occurrence? occurrence,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _EventEditor(day: day, occurrence: occurrence),
    ),
  );
}

enum _Repeat {
  none('Nie', null, 1),
  daily('Täglich', RecurrenceFrequency.daily, 1),
  weekly('Wöchentlich', RecurrenceFrequency.weekly, 1),
  biweekly('Alle 2 Wochen', RecurrenceFrequency.weekly, 2),
  monthly('Monatlich', RecurrenceFrequency.monthly, 1),
  yearly('Jährlich', RecurrenceFrequency.yearly, 1);

  const _Repeat(this.label, this.frequency, this.interval);

  final String label;
  final RecurrenceFrequency? frequency;
  final int interval;

  static _Repeat of(Recurrence? r) => r == null
      ? none
      : values.firstWhere(
          (v) => v.frequency == r.frequency && v.interval == r.interval,
          orElse: () => switch (r.frequency) {
            RecurrenceFrequency.daily => daily,
            RecurrenceFrequency.weekly => weekly,
            RecurrenceFrequency.monthly => monthly,
            RecurrenceFrequency.yearly => yearly,
          },
        );
}

const _timedReminders = {
  0: 'Zum Beginn',
  5: '5 Minuten vorher',
  15: '15 Minuten vorher',
  30: '30 Minuten vorher',
  60: '1 Stunde vorher',
  120: '2 Stunden vorher',
  1440: '1 Tag vorher',
};

/// Relative to midnight of the day; negative = after midnight.
const _allDayReminders = {
  -480: 'Am Tag um 8:00',
  360: 'Am Vortag um 18:00',
  1800: '2 Tage vorher um 18:00',
  9600: '1 Woche vorher um 8:00',
};

enum _Scope { this_, all }

class _EventEditor extends StatefulWidget {
  const _EventEditor({this.day, this.occurrence});

  final DateTime? day;
  final Occurrence? occurrence;

  @override
  State<_EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<_EventEditor> {
  late final CalendarEvent? _original = widget.occurrence?.event;
  late final _title = TextEditingController(text: _original?.title);
  late final _location = TextEditingController(text: _original?.location);
  late final _notes = TextEditingController(text: _original?.notes);

  late bool _allDay;
  late DateTime _start;
  late DateTime _end;
  late _Repeat _repeat;
  DateTime? _until;

  /// Weekly series: the days of the week (1 = Monday).
  var _weekdays = <int>{};
  late Set<String> _memberIds;
  int? _reminder;
  var _confidential = false;
  String? _bringerId;
  String? _pickerId;
  var _countdown = false;

  bool get _isSeries => _original?.recurrence != null;

  @override
  void initState() {
    super.initState();
    final o = widget.occurrence;
    if (o != null) {
      _allDay = o.event.allDay;
      _start = o.start;
      _end = o.end;
      _repeat = _Repeat.of(o.event.recurrence);
      _until = o.event.recurrence?.until;
      _weekdays = {...?o.event.recurrence?.weekdays};
      _memberIds = {...o.event.memberIds};
      _reminder = o.event.reminderMinutes;
      _confidential = o.event.confidential;
      _bringerId = o.event.bringerId;
      _pickerId = o.event.pickerId;
      _countdown = o.event.countdown;
    } else {
      final day = widget.day ?? DateUtils.dateOnly(DateTime.now());
      final now = DateTime.now();
      // Next full hour today, 9:00 on other days.
      final hour = DateUtils.isSameDay(day, now)
          ? (now.hour + 1).clamp(0, 23)
          : 9;
      _allDay = false;
      _start = DateTime(day.year, day.month, day.day, hour);
      _end = _start.add(const Duration(hours: 1));
      _repeat = _Repeat.none;
      _memberIds = {};
      _reminder = 15;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// Last day shown to the user; all-day ends are stored exclusive.
  DateTime get _endDay => _allDay
      ? DateTime(_end.year, _end.month, _end.day - 1)
      : DateUtils.dateOnly(_end);

  void _setAllDay(bool allDay) => setState(() {
    if (allDay == _allDay) return;
    _allDay = allDay;
    final startDay = DateUtils.dateOnly(_start);
    final endDay = DateUtils.dateOnly(_end);
    if (allDay) {
      _start = startDay;
      _end = DateTime(endDay.year, endDay.month, endDay.day + 1);
      _reminder = _reminder == null ? null : 360;
    } else {
      _start = DateTime(startDay.year, startDay.month, startDay.day, 9);
      _end = _start.add(const Duration(hours: 1));
      _reminder = _reminder == null ? null : 15;
    }
  });

  Future<void> _pickStartDate() async {
    final picked = await _pickDate(_start);
    if (picked == null) return;
    setState(() {
      final length = _end.difference(_start);
      _start = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _start.hour,
        _start.minute,
      );
      _end = _start.add(length);
    });
  }

  Future<void> _pickEndDate() async {
    final picked = await _pickDate(_endDay);
    if (picked == null) return;
    setState(() {
      _end = _allDay
          ? DateTime(picked.year, picked.month, picked.day + 1)
          : DateTime(
              picked.year,
              picked.month,
              picked.day,
              _end.hour,
              _end.minute,
            );
      _fixOrder();
    });
  }

  Future<void> _pickTime({required bool start}) async {
    final value = start ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(value),
    );
    if (picked == null) return;
    setState(() {
      final updated = DateTime(
        value.year,
        value.month,
        value.day,
        picked.hour,
        picked.minute,
      );
      if (start) {
        final length = _end.difference(_start);
        _start = updated;
        _end = _start.add(length);
      } else {
        _end = updated;
        _fixOrder();
      }
    });
  }

  void _fixOrder() {
    if (!_end.isBefore(_start)) return;
    if (_allDay) {
      _end = DateTime(_start.year, _start.month, _start.day + 1);
    } else {
      _end = _start.add(const Duration(hours: 1));
    }
  }

  Future<DateTime?> _pickDate(DateTime initial) => showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(1900),
    lastDate: DateTime(2100),
  );

  CalendarEvent _edited(String id) => CalendarEvent(
    id: id,
    title: _title.text.trim(),
    start: _start,
    end: _end,
    allDay: _allDay,
    location: _location.text.trim(),
    notes: _notes.text.trim(),
    memberIds: _memberIds.toList(),
    recurrence: _repeat.frequency == null
        ? null
        : Recurrence(
            _repeat.frequency!,
            interval: _repeat.interval,
            until: _until,
            weekdays: _repeat.frequency == RecurrenceFrequency.weekly
                ? _weekdayList()
                : const [],
          ),
    reminderMinutes: _reminder,
    confidential: _confidential,
    bringerId: _allDay ? null : _bringerId,
    pickerId: _allDay ? null : _pickerId,
    countdown: _countdown,
    // Other calendar apps (CalDAV) know the event by its UID.
    icalUid: id == _original?.id ? _original?.icalUid : null,
  );

  /// Selected weekdays; only the start's weekday means "none given".
  List<int> _weekdayList() {
    final days = Recurrence.normalizeWeekdays(_weekdays);
    return days.length == 1 && days.single == _start.weekday ? const [] : days;
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte einen Titel eingeben')),
      );
      return;
    }
    final engine = AppScope.engineOf(context);
    final original = _original;
    final occurrence = widget.occurrence;

    if (original == null || occurrence == null) {
      engine.saveEvent(_edited(newId()));
    } else if (!_isSeries) {
      engine.saveEvent(
        _edited(original.id).copyWith(exceptions: original.exceptions),
      );
    } else {
      final scope = await _askScope('Änderung speichern');
      if (scope == null) return;
      if (scope == _Scope.this_) {
        // Detach this occurrence as a standalone event.
        engine.saveEvent(_skip(original, occurrence));
        engine.saveEvent(_edited(newId()).copyWith(recurrence: null));
      } else {
        // Shift the whole series by how much this occurrence was moved.
        final shift = _start.difference(occurrence.start);
        final start = original.start.add(shift);
        engine.saveEvent(
          _edited(original.id).copyWith(
            start: start,
            end: start.add(_end.difference(_start)),
            exceptions: original.exceptions,
          ),
        );
      }
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final engine = AppScope.engineOf(context);
    final original = _original!;
    if (_isSeries) {
      final scope = await _askScope('Termin löschen');
      if (scope == null) return;
      if (scope == _Scope.this_) {
        engine.saveEvent(_skip(original, widget.occurrence!));
      } else if (mounted) {
        _deleteWithUndo(engine, original);
      }
    } else {
      _deleteWithUndo(engine, original);
    }
    if (mounted) Navigator.pop(context);
  }

  void _deleteWithUndo(SyncEngine engine, CalendarEvent event) =>
      deleteWithUndo(
        context,
        what: event.title,
        collections: const {Collections.events},
        delete: () => engine.deleteEvent(event.id),
      );

  static CalendarEvent _skip(CalendarEvent series, Occurrence o) =>
      series.copyWith(
        exceptions: {...series.exceptions, DateUtils.dateOnly(o.start)},
      );

  Future<_Scope?> _askScope(String title) => showDialog<_Scope>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, _Scope.this_),
          child: const Text('Nur dieser Termin'),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, _Scope.all),
          child: const Text('Alle Termine der Serie'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final theme = Theme.of(context);
    final dateFormat = DateFormat('E, d. MMM y', 'de');
    final reminders = _allDay ? _allDayReminders : _timedReminders;

    Widget dateRow(
      String label,
      DateTime day,
      VoidCallback onDate,
      VoidCallback onTime,
      DateTime time,
    ) => Row(
      children: [
        SizedBox(width: 56, child: Text(label)),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onDate,
              child: Text(dateFormat.format(day)),
            ),
          ),
        ),
        if (!_allDay)
          TextButton(onPressed: onTime, child: Text(timeLabel(time))),
      ],
    );

    return SectionPage(
      section: FamioSection.calendar,
      title: _original == null ? 'Neuer Termin' : 'Termin bearbeiten',
      actions: [
        ColorButton(
          label: 'Speichern',
          color: FamioColors.of(context).strong(FamioSection.calendar),
          onPressed: _save,
        ),
      ],
      bodyPadding: EdgeInsets.zero,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.fromLTRB(20, 8, 20, listBottomPadding(context)),
            children: [
              TextField(
                controller: _title,
                autofocus: _original == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Titel'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                secondary: const Icon(AppIcons.sun),
                title: const Text('Ganztägig'),
                value: _allDay,
                onChanged: _setAllDay,
              ),
              dateRow(
                'Beginn',
                _start,
                _pickStartDate,
                () => _pickTime(start: true),
                _start,
              ),
              dateRow(
                'Ende',
                _endDay,
                _pickEndDate,
                () => _pickTime(start: false),
                _end,
              ),
              const Divider(height: 32),
              DropdownButtonFormField<_Repeat>(
                initialValue: _repeat,
                decoration: const InputDecoration(
                  labelText: 'Wiederholen',
                  prefixIcon: Icon(AppIcons.repeat),
                ),
                items: [
                  for (final r in _Repeat.values)
                    DropdownMenuItem(value: r, child: Text(r.label)),
                ],
                onChanged: (r) => setState(() => _repeat = r ?? _Repeat.none),
              ),
              if (_repeat.frequency == RecurrenceFrequency.weekly) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (i, label) in const [
                      'Mo',
                      'Di',
                      'Mi',
                      'Do',
                      'Fr',
                      'Sa',
                      'So',
                    ].indexed)
                      FilterChip(
                        label: Text(label),
                        showCheckmark: false,
                        selected: _weekdays.isEmpty
                            ? i + 1 == _start.weekday
                            : _weekdays.contains(i + 1),
                        onSelected: (on) => setState(() {
                          if (_weekdays.isEmpty) _weekdays = {_start.weekday};
                          on ? _weekdays.add(i + 1) : _weekdays.remove(i + 1);
                        }),
                      ),
                  ],
                ),
              ],
              if (_repeat != _Repeat.none) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const SizedBox(width: 12),
                    const Text('Endet'),
                    const Spacer(),
                    InputChip(
                      label: Text(
                        _until == null
                            ? 'Nie'
                            : 'am ${dateFormat.format(_until!)}',
                      ),
                      onPressed: () async {
                        final picked = await _pickDate(_until ?? _start);
                        if (picked != null) setState(() => _until = picked);
                      },
                      onDeleted: _until == null
                          ? null
                          : () => setState(() => _until = null),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              DropdownButtonFormField<int?>(
                // Keep a stored value visible even if it is not a preset.
                initialValue: _reminder,
                key: ValueKey(_allDay),
                decoration: const InputDecoration(
                  labelText: 'Erinnerung',
                  prefixIcon: Icon(AppIcons.bell),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Keine')),
                  for (final e in reminders.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                  if (_reminder != null && !reminders.containsKey(_reminder))
                    DropdownMenuItem(
                      value: _reminder,
                      child: Text('$_reminder Minuten vorher'),
                    ),
                ],
                onChanged: (v) => setState(() => _reminder = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(AppIcons.lock),
                title: const Text('Vertraulich'),
                subtitle: const Text(
                  'Nicht in Kalender-Abos (Google, Apple …) – z. B. für '
                  'Arzttermine',
                ),
                value: _confidential,
                onChanged: (v) => setState(() => _confidential = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(AppIcons.partyPopper),
                title: const Text('Countdown'),
                subtitle: const Text(
                  'Auf der Startseite und der Wandanzeige: „Noch 12 Tage“',
                ),
                value: _countdown,
                onChanged: (v) => setState(() => _countdown = v),
              ),
              const SizedBox(height: 8),
              if (!_allDay) ...[
                Text('Wer fährt?', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                for (final (label, value, set) in [
                  ('Bringt', _bringerId, (String? v) => _bringerId = v),
                  ('Holt ab', _pickerId, (String? v) => _pickerId = v),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DropdownButtonFormField<String?>(
                      initialValue: engine.members.any((m) => m.id == value)
                          ? value
                          : null,
                      decoration: InputDecoration(
                        labelText: label,
                        prefixIcon: const Icon(AppIcons.car),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Niemand eingeteilt'),
                        ),
                        for (final m in engine.members)
                          if (!m.isChild)
                            DropdownMenuItem(
                              value: m.id,
                              child: Text(m.displayName),
                            ),
                      ],
                      onChanged: (v) => setState(() => set(v)),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
              Text('Wer ist dabei?', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    avatar: const Icon(AppIcons.usersThree, size: 18),
                    label: const Text('Ganze Familie'),
                    selected: _memberIds.isEmpty,
                    onSelected: (_) => setState(_memberIds.clear),
                  ),
                  for (final m in engine.members)
                    FilterChip(
                      avatar: MemberAvatar(m, radius: 10),
                      label: Text(m.displayName),
                      selected: _memberIds.contains(m.id),
                      onSelected: (on) => setState(
                        () =>
                            on ? _memberIds.add(m.id) : _memberIds.remove(m.id),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _location,
                decoration: const InputDecoration(
                  labelText: 'Ort',
                  prefixIcon: Icon(AppIcons.mapPin),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                minLines: 2,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Notizen',
                  prefixIcon: Icon(AppIcons.note),
                ),
              ),
              if (_original != null) ...[
                const SizedBox(height: 8),
                EventComments(eventId: _original.id),
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(AppIcons.trash),
                    label: const Text('Termin löschen'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: _delete,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
