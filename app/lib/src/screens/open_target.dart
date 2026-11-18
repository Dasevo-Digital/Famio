import 'dart:async';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/palette.dart';
import '../security/app_lock.dart';
import 'calendar_screen.dart';
import 'chat_screens.dart';
import 'deadlines_screen.dart';
import 'deferred_sections.dart';
import 'home_shell.dart';
import 'loans_screen.dart';
import 'settings_screen.dart';
import 'tasks_screen.dart';
import 'waste_screen.dart';

/// Opens what a tapped notification is about (#385): its section, there
/// the task or appointment, the chat, the child or the page. What no
/// longer exists or is not for this member opens only its section, or
/// nothing where the section is not theirs (a guest, a section switched
/// off). With the app lock on, it waits until the person has unlocked.
/// [go] switches to a section, [navigatorOf] gives its page stack.
Future<void> openNoticeTarget(
  BuildContext context,
  NoticeTarget target, {
  required void Function(FamioSection section) go,
  required NavigatorState? Function(FamioSection section) navigatorOf,
}) async {
  final state = AppScope.read(context);
  final engine = state.engine;
  if (engine == null) return;
  bool active() => context.mounted && identical(state.engine, engine);
  bool visible(FamioSection section) =>
      active() &&
      state.me != null &&
      sectionsFor(
        state.me!.role,
        hidden: state.hiddenModules,
      ).contains(section);
  await _unlocked(state.lock);
  if (!active()) return;

  CalendarEvent? event() =>
      engine.event(target.id) ??
      engine.externalEvents.where((e) => e.id == target.id).firstOrNull;
  bool chat() =>
      target.id == ChatIds.family ||
      engine.members.any(
        (m) => ChatIds.direct(engine.memberId, m.id) == target.id,
      );

  final section = switch (target.kind) {
    NoticeTarget.taskKind => FamioSection.tasks,
    NoticeTarget.eventKind => FamioSection.calendar,
    NoticeTarget.chatKind => FamioSection.chat,
    NoticeTarget.childKind || NoticeTarget.pregnancyKind => FamioSection.kids,
    _ => null,
  };
  if (section != null && !visible(section)) return;
  await _waitForFirstSync(
    state,
    engine,
    () => switch (target.kind) {
      NoticeTarget.taskKind =>
        engine.record(Collections.tasks, target.id) != null,
      NoticeTarget.eventKind => event() != null,
      NoticeTarget.chatKind => chat(),
      NoticeTarget.childKind => engine.child(target.id) != null,
      NoticeTarget.pregnancyKind => engine.pregnancy(target.id) != null,
      NoticeTarget.sosKind =>
        engine.record(Collections.sosAlerts, target.id) != null,
      _ => true,
    },
  );
  if (!active()) return;
  await _unlocked(state.lock);
  if (!context.mounted || !identical(state.engine, engine)) return;

  /// The section [s] on screen at its start page; null when it is not this
  /// member's.
  Future<NavigatorState?> at(FamioSection s) async {
    if (!visible(s)) return null;
    go(s);
    await WidgetsBinding.instance.endOfFrame;
    if (!visible(s)) return null;
    final navigator = navigatorOf(s);
    navigator?.popUntil((r) => r.isFirst);
    return navigator != null && navigator.mounted ? navigator : null;
  }

  Future<void> push(NavigatorState navigator, Widget page) =>
      navigator.push(MaterialPageRoute<void>(builder: (_) => page));

  switch (target.kind) {
    case NoticeTarget.taskKind:
      final page = (await at(FamioSection.tasks))?.context;
      if (page != null && page.mounted) {
        final task = engine.tasks.where((t) => t.id == target.id).firstOrNull;
        if (task != null) await showTaskEditor(page, task: task);
      }
    case NoticeTarget.eventKind:
      final page = (await at(FamioSection.calendar))?.context;
      if (page == null || !page.mounted) return;
      final appointment = event();
      if (appointment != null) {
        final occurrence = _occurrence(appointment, target.at);
        CalendarScreen.requestedDay.value = occurrence.start;
        await showCalendarOccurrence(page, engine, occurrence);
      }
    case NoticeTarget.dayKind:
      if (await at(FamioSection.calendar) != null) {
        CalendarScreen.requestedDay.value = target.at;
      }
    case NoticeTarget.chatKind:
      final navigator = await at(FamioSection.chat);
      if (navigator != null && chat()) {
        await push(
          navigator,
          ChatScreen(chatId: target.id, title: chatTitle(engine, target.id)),
        );
      }
    case NoticeTarget.childKind:
      final navigator = await at(FamioSection.kids);
      if (navigator != null && engine.child(target.id) != null) {
        await push(navigator, childPage(target.id));
      }
    case NoticeTarget.pregnancyKind:
      final navigator = await at(FamioSection.kids);
      if (navigator != null && engine.pregnancy(target.id) != null) {
        await push(navigator, pregnancyPage(target.id));
      }
    case NoticeTarget.sosKind:
      // Above everything, as when opened from the banner.
      if (engine.record(Collections.sosAlerts, target.id) != null) {
        await Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute<void>(builder: (_) => sosAlertPage(target.id)),
        );
      }
    case NoticeTarget.sectionKind:
      final section = FamioSection.values
          .where((s) => s.name == target.id)
          .firstOrNull;
      if (section != null) await at(section);
    case NoticeTarget.pageKind:
      final (section, page) = switch (target.id) {
        NoticeTarget.deadlines => (
          FamioSection.home,
          const DeadlinesScreen() as Widget,
        ),
        NoticeTarget.loans => (FamioSection.home, const LoansScreen()),
        NoticeTarget.waste => (FamioSection.home, const WasteScreen()),
        NoticeTarget.subscriptions => (
          FamioSection.budget,
          subscriptionsPage(),
        ),
        NoticeTarget.devices => (
          FamioSection.settings,
          const MyDevicesScreen(),
        ),
        _ => (null, null),
      };
      if (section == null || page == null) return;
      final navigator = await at(section);
      if (navigator != null) await push(navigator, page);
  }
}

/// A fresh session can already display the shell while its first pull runs.
/// Stop waiting when it completes, goes offline, the session changes or the
/// time limit expires. Local targets can open as soon as they arrive.
Future<void> _waitForFirstSync(
  AppState state,
  SyncEngine engine,
  bool Function() available,
) async {
  bool done() {
    final status = engine.status;
    return !identical(state.engine, engine) ||
        status.lastSync != null ||
        status.state == SyncState.offline ||
        status.state == SyncState.unauthorized ||
        available();
  }

  if (done()) return;
  final ready = Completer<void>();
  void finish() {
    if (!ready.isCompleted) ready.complete();
  }

  void check() {
    if (done()) finish();
  }

  final changes = engine.changes.listen((_) => check(), onDone: finish);
  final statuses = engine.statusChanges.listen((_) => check());
  state.addListener(check);
  final timeout = Timer(const Duration(seconds: 8), finish);
  try {
    await ready.future;
  } finally {
    timeout.cancel();
    state.removeListener(check);
    unawaited(changes.cancel());
    unawaited(statuses.cancel());
  }
}

/// The date [at] of [event], else its next one (or its first, when it is
/// over).
Occurrence _occurrence(CalendarEvent event, DateTime? at) {
  if (at != null) {
    final found = event
        .occurrencesBetween(
          at.subtract(const Duration(minutes: 1)),
          at.add(const Duration(minutes: 1)),
        )
        .where((o) => o.start.isAtSameMomentAs(at))
        .firstOrNull;
    if (found != null) return found;
  }
  final now = DateTime.now();
  return event
          .occurrencesBetween(now, now.add(const Duration(days: 400)))
          .firstOrNull ??
      Occurrence(event, event.start, event.end);
}

/// Returns once the app lock (if on) no longer covers the app.
Future<void> _unlocked(AppLock lock) {
  if (!lock.locked && !lock.covered) return Future.value();
  final done = Completer<void>();
  void check() {
    if (!lock.locked && !lock.covered && !done.isCompleted) {
      lock.removeListener(check);
      done.complete();
    }
  }

  lock.addListener(check);
  return done.future;
}
