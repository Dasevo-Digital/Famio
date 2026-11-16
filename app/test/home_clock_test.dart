// The start page and the year in review at a chosen time of day and date
// (catalog GRU-056, GRU-061, HAU-138): the app reads the time through
// package:clock, the tests set it with withClock.
import 'package:clock/clock.dart';
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/year_review_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mama = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
const _gast = FamilyMember(
  id: 'g1',
  username: 'oma',
  displayName: 'Oma',
  role: MemberRole.guest,
);

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama"},'
    '{"id":"g1","username":"oma","displayName":"Oma","role":"guest"}]';

/// Famio signed in as [me], on its start page, at [now].
Future<void> _start(
  WidgetTester tester,
  DateTime now, {
  FamilyMember me = _mama,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final state = AppState();
  await state.init();
  final engine = SyncEngine(
    store: LocalStore.open(':memory:')..setMeta('members', _members),
    api: FamioApiClient('localhost:1'),
    memberId: me.id,
  );
  state
    ..me = me
    ..engine = engine;
  await withClock(Clock.fixed(now), () async {
    await tester.pumpWidget(FamioApp(state: state));
    await tester.tap(find.text('Start').first);
    await tester.pumpAndSettle();
  });
}

/// Pumps at [now] (the page builds again only when pumped).
Future<void> _at(
  WidgetTester tester,
  DateTime now,
  Future<void> Function() f,
) => withClock(Clock.fixed(now), f);

/// Lets the sync debounce of the engine run out.
Future<void> _end(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 1));

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('GRU-056 greeting by the time of day', () {
    for (final (hour, minute, greeting) in [
      (4, 59, 'Gute Nacht'),
      (5, 0, 'Guten Morgen'),
      (9, 0, 'Guten Morgen'),
      (10, 59, 'Guten Morgen'),
      (11, 0, 'Hallo'),
      (14, 0, 'Hallo'),
      (16, 59, 'Hallo'),
      (17, 0, 'Guten Abend'),
      (20, 0, 'Guten Abend'),
      (21, 59, 'Guten Abend'),
      (22, 0, 'Gute Nacht'),
      (23, 0, 'Gute Nacht'),
      (0, 0, 'Gute Nacht'),
    ]) {
      final label =
          '${hour.toString().padLeft(2, '0')}:'
          '${minute.toString().padLeft(2, '0')}';
      testWidgets('$label: $greeting', (tester) async {
        final now = DateTime(2026, 11, 16, hour, minute);
        await _start(tester, now);
        expect(find.text('$greeting, Mama!'), findsOneWidget);
        // The date below it, of the same clock.
        expect(find.text('Montag, 16. November'), findsWidgets);
        expect(find.text(DateFormat.MMMMEEEEd('de').format(now)), findsWidgets);
        await _end(tester);
      });
    }

    testWidgets('on another day the date below it changes too', (tester) async {
      await _start(tester, DateTime(2026, 12, 24, 20));
      expect(find.text('Guten Abend, Mama!'), findsOneWidget);
      expect(find.text('Donnerstag, 24. Dezember'), findsWidgets);
      await _end(tester);
    });
  });

  group('GRU-061 HAU-138 the year in review on the start page', () {
    final hint = find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').endsWith(' im Rückblick ansehen'),
    );

    for (final (day, year) in [
      (DateTime(2026, 12, 14, 23, 59), null),
      (DateTime(2026, 12, 15), 2026),
      (DateTime(2026, 12, 31, 23, 59), 2026),
      (DateTime(2027, 1, 1), 2026),
      (DateTime(2027, 1, 31, 23, 59), 2026),
      (DateTime(2027, 2, 1), null),
      (DateTime(2027, 3, 10, 9), null),
      (DateTime(2026, 11, 30, 12), null),
    ]) {
      final label = DateFormat('dd.MM.yyyy HH:mm').format(day);
      testWidgets(
        '$label: ${year == null ? 'no card' : '"$year im Rückblick ansehen"'}',
        (tester) async {
          await _start(tester, day);
          if (year == null) {
            expect(hint, findsNothing);
          } else {
            expect(find.text('$year im Rückblick ansehen'), findsOneWidget);
            expect(hint, findsOneWidget);
          }
          await _end(tester);
        },
      );
    }

    testWidgets('not for guests in December', (tester) async {
      await _start(tester, DateTime(2026, 12, 20, 10), me: _gast);
      expect(find.text('Guten Morgen, Oma!'), findsOneWidget);
      expect(hint, findsNothing);
      await _end(tester);
    });

    testWidgets('not for guests in January', (tester) async {
      await _start(tester, DateTime(2027, 1, 10, 10), me: _gast);
      expect(hint, findsNothing);
      await _end(tester);
    });

    testWidgets('the card opens the review of its year, in January the past '
        'one', (tester) async {
      final now = DateTime(2027, 1, 10, 10);
      await _start(tester, now);
      await _at(tester, now, () async {
        await tester.tap(find.text('2026 im Rückblick ansehen'));
        await tester.pumpAndSettle();
        expect(find.byType(YearReviewScreen), findsOneWidget);
        expect(find.text(tr.yearReviewTitle(2026)), findsOneWidget);
        // 2027 is the current year: one further, then no more.
        final next = find.byTooltip(tr.yearReviewNext);
        expect(_enabled(tester, next), isTrue);
        await tester.tap(next);
        await tester.pumpAndSettle();
        expect(find.text(tr.yearReviewTitle(2027)), findsOneWidget);
        expect(_enabled(tester, next), isFalse);
      });
      await _end(tester);
    });

    testWidgets('in December the card opens the current year', (tester) async {
      final now = DateTime(2026, 12, 20, 10);
      await _start(tester, now);
      await _at(tester, now, () async {
        await tester.tap(find.text('2026 im Rückblick ansehen'));
        await tester.pumpAndSettle();
        expect(find.text(tr.yearReviewTitle(2026)), findsOneWidget);
        expect(_enabled(tester, find.byTooltip(tr.yearReviewNext)), isFalse);
      });
      await _end(tester);
    });
  });

  group('HAU-138 Einstellungen → Jahresrückblick', () {
    for (final (now, year) in [
      (DateTime(2026, 11, 16, 10), 2025),
      (DateTime(2026, 11, 30, 23, 59), 2025),
      (DateTime(2026, 12, 1), 2026),
      (DateTime(2026, 12, 31, 12), 2026),
      (DateTime(2027, 1, 15, 12), 2026),
    ]) {
      final label = DateFormat('dd.MM.yyyy HH:mm').format(now);
      testWidgets('$label: "Unser Jahr $year"', (tester) async {
        await _start(tester, now);
        await _at(tester, now, () async {
          await tester.tap(find.text('Einstellungen').first);
          await tester.pumpAndSettle();
          final menu = find.text(tr.yearReviewMenu);
          await tester.scrollUntilVisible(
            menu,
            300,
            scrollable: find
                .descendant(
                  of: find.byType(ListView).last,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.tap(menu);
          await tester.pumpAndSettle();
          expect(find.byType(YearReviewScreen), findsOneWidget);
          expect(find.text(tr.yearReviewTitle(year)), findsOneWidget);
          // Forward up to the current year only.
          final next = find.byTooltip(tr.yearReviewNext);
          for (var y = year; y < now.year; y++) {
            expect(_enabled(tester, next), isTrue, reason: '$y');
            await tester.tap(next);
            await tester.pumpAndSettle();
          }
          expect(find.text(tr.yearReviewTitle(now.year)), findsOneWidget);
          expect(_enabled(tester, next), isFalse);
        });
        await _end(tester);
      });
    }
  });
}

/// Whether the round button with [tooltip] can be tapped.
bool _enabled(WidgetTester tester, Finder tooltip) =>
    tester
        .widget<BubbleButton>(
          find.ancestor(of: tooltip, matching: find.byType(BubbleButton)).first,
        )
        .onPressed !=
    null;
