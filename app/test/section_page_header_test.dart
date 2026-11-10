// Page titles stay readable on narrow phones: when the buttons next to the
// title leave no room for it, they move to a row of their own.
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/design/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> show(
    WidgetTester tester, {
    required double width,
    int buttons = 6,
    String title = 'Kalender',
    Widget? leading,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: famioTheme(Brightness.light),
        home: SectionPage(
          section: FamioSection.calendar,
          title: title,
          subtitle: 'Dienstag, 10. November',
          leading: leading,
          actions: [
            for (var i = 0; i < buttons; i++)
              BubbleButton(
                key: ValueKey('button$i'),
                icon: AppIcons.magnifyingGlass,
                onPressed: () {},
              ),
          ],
          body: const SizedBox.expand(),
        ),
      ),
    );
  }

  RenderParagraph paragraph(WidgetTester tester, String text) =>
      tester.renderObject<RenderParagraph>(find.text(text));

  testWidgets('a narrow phone shows the whole title above the buttons', (
    tester,
  ) async {
    await show(tester, width: 402);
    expect(paragraph(tester, 'Kalender').didExceedMaxLines, isFalse);
    final title = tester.getRect(find.text('Kalender'));
    final subtitle = tester.getRect(find.text('Dienstag, 10. November'));
    for (var i = 0; i < 6; i++) {
      final button = tester.getRect(find.byKey(ValueKey('button$i')));
      expect(button.top, greaterThan(subtitle.top));
      expect(button.right, lessThanOrEqualTo(402 - 12 + 0.01));
    }
    // The buttons keep their place at the end of the row.
    expect(
      tester.getRect(find.byKey(const ValueKey('button5'))).right,
      closeTo(402 - 12, 0.01),
    );
    expect(title.left, 20);
    // They still work in their own row.
    await tester.tap(find.byKey(const ValueKey('button0')));
  });

  testWidgets('a wide screen keeps title and buttons in one row', (
    tester,
  ) async {
    await show(tester, width: 1000);
    final title = tester.getRect(find.text('Kalender'));
    final button = tester.getRect(find.byKey(const ValueKey('button0')));
    expect(button.left, greaterThan(title.right));
    expect(button.top, lessThan(title.bottom));
  });

  testWidgets('a page without buttons gets no extra row', (tester) async {
    await show(tester, width: 402, buttons: 0, title: 'Ein sehr langer Titel');
    final subtitle = tester.getRect(find.text('Dienstag, 10. November'));
    // Header padding 16 + title + subtitle + 12: the body starts right after.
    final body = tester.getRect(find.byType(SizedBox).last);
    expect(body.top - subtitle.bottom, closeTo(12, 0.01));
  });

  testWidgets('the leading button stays in front of the title', (tester) async {
    await show(
      tester,
      width: 402,
      leading: const SizedBox(key: ValueKey('back'), width: 60, height: 48),
    );
    final back = tester.getRect(find.byKey(const ValueKey('back')));
    final title = tester.getRect(find.text('Kalender'));
    expect(title.left, back.right);
    expect(paragraph(tester, 'Kalender').didExceedMaxLines, isFalse);
  });
}
