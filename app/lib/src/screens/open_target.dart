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
import 'event_editor.dart';
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
  await _unlocked(state.lock);
  if (!context.mounted) return;
  final engine = state.engine;
  final me = state.me;
  if (engine == null || me == null) return;
  final visible = sectionsFor(me.role, hidden: state.hiddenModules).toSet();

  /// The section [s] on screen at its start page; null when it is not this
  /// member's.
  Future<NavigatorState?> at(FamioSection s) async {
    if (!visible.contains(s)) return null;
    go(s);
    await WidgetsBinding.instance.endOfFrame;
    final navigator = navigatorOf(s);
    navigator?.popUntil((r) => r.isFirst);
    return navigator != null && navigator.mounted ? navigator : null;
  }

  Future<void> push(NavigatorState navigator, Widget page) =>
      navigator.push(MaterialPageRoute<void>(builder: (_) => page));

  switch (target.kind) {
    case NoticeTarget.taskKind:
      final page = (await at(FamioSection.tasks))?.context;
      final task = engine.tasks.where((t) => t.id == target.id).firstOrNull;
      if (page != null && page.mounted && task != null) {
        await showTaskEditor(page, task: task);
      }
    case NoticeTarget.eventKind:
      final event = engine.events.where((e) => e.id == target.id).firstOrNull;
      final occurrence = event == null ? null : _occurrence(event, target.at);
      if (occurrence != null) {
        CalendarScreen.requestedDay.value = occurrence.start;
      }
      final page = (await at(FamioSection.calendar))?.context;
      if (page != null && page.mounted && occurrence != null) {
        await showEventEditor(page, occurrence: occurrence);
      }
    case NoticeTarget.dayKind:
      CalendarScreen.requestedDay.value = target.at;
      await at(FamioSection.calendar);
    case NoticeTarget.chatKind:
      final navigator = await at(FamioSection.chat);
      final ours =
          target.id == ChatIds.family ||
          engine.members.any(
            (m) => ChatIds.direct(engine.memberId, m.id) == target.id,
          );
      if (navigator != null && ours) {
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

/// The date [at] of [event], else its next one (or its first, when it is
/// over).
Occurrence? _occurrence(CalendarEvent event, DateTime? at) {
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
