import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/plain_text.dart';
import '../data/week_plan.dart';
import '../design/palette.dart';
import '../l10n.dart';

// Its own library: the web app fetches the PDF package only when someone
// prints (see deferred_sections.dart).

/// The week plan as an A4 page for the fridge: a row per day with the
/// appointments, meals, chores and bins, then the chores of every day and
/// of the week. Rows that do not fit go on to a second page.
Future<Uint8List> weekPlanPdf(WeekPlan plan, {DateTime? now}) async {
  Future<pw.Font> font(String name) async =>
      pw.Font.ttf(await rootBundle.load('assets/fonts/$name.ttf'));
  final regular = await font('Nunito-400');
  final bold = await font('Nunito-800');
  final title = await font('Fredoka-600');
  final accent = PdfColor.fromInt(
    FamioColors.light.sectionText(FamioSection.calendar).toARGB32(),
  );
  // Half the section's tint: the weekend stands out without much ink.
  final section = PdfColor.fromInt(
    FamioColors.light.tint(FamioSection.calendar).toARGB32(),
  );
  final tint = PdfColor(
    1 - (1 - section.red) / 2,
    1 - (1 - section.green) / 2,
    1 - (1 - section.blue) / 2,
  );
  const grey = PdfColors.grey600;
  const line = PdfColors.grey400;
  final last = DateTime(
    plan.monday.year,
    plan.monday.month,
    plan.monday.day + 6,
  );
  final range =
      '${DateFormat.MMMd(appLanguage).format(plan.monday)} – '
      '${DateFormat.yMMMd(appLanguage).format(last)}';
  final weekday = DateFormat.E(appLanguage);
  final date = DateFormat.Md(appLanguage);
  final today = now ?? DateTime.now();
  final small = pw.TextStyle(fontSize: 8, color: grey);

  String who(List<String> names) =>
      names.isEmpty ? '' : ' (${names.map(withoutEmoji).join(', ')})';

  pw.Widget cell(List<pw.Widget> children, {double minHeight = 0}) =>
      pw.ConstrainedBox(
        constraints: pw.BoxConstraints(minHeight: minHeight),
        child: pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: children,
          ),
        ),
      );
  pw.Widget entry(String text, {String? lead, String? sub}) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 2),
    child: pw.RichText(
      text: pw.TextSpan(
        style: const pw.TextStyle(fontSize: 9.5),
        children: [
          if (lead != null)
            pw.TextSpan(
              text: '$lead ',
              style: pw.TextStyle(font: bold),
            ),
          pw.TextSpan(text: withoutEmoji(text)),
          if (sub != null && sub.isNotEmpty)
            pw.TextSpan(
              text: ' · ${withoutEmoji(sub)}',
              style: const pw.TextStyle(color: grey),
            ),
        ],
      ),
    ),
  );
  pw.Widget header(String text) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
    child: pw.Text(
      text,
      style: pw.TextStyle(font: bold, fontSize: 9, color: PdfColors.white),
    ),
  );

  // Quiet days still get room to write on: the rows fill the page unless
  // the week is too full for one.
  final boxes = (plan.everyDay.isEmpty ? 0 : 1) + (plan.weekly.isEmpty ? 0 : 1);
  final rowHeight =
      (PdfPageFormat.a4.height - 60 - 50 - 20 - 24 - boxes * 56) / 7 * 0.92;

  pw.TableRow row(WeekPlanDay d) {
    final weekend = d.day.weekday >= DateTime.saturday;
    return pw.TableRow(
      decoration: weekend ? pw.BoxDecoration(color: tint) : null,
      children: [
        cell(minHeight: rowHeight, [
          pw.Text(
            weekday.format(d.day).replaceAll('.', ''),
            style: pw.TextStyle(font: title, fontSize: 14, color: accent),
          ),
          pw.Text(date.format(d.day), style: small),
          if (d.holiday case final h?)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 2),
              child: pw.Text(withoutEmoji(h), style: small),
            ),
        ]),
        cell([
          for (final e in d.events) entry(e.title, lead: e.time, sub: e.people),
        ]),
        cell([
          for (final m in d.meals)
            entry(m.title, lead: d.meals.length > 1 ? m.slot.label : null),
        ]),
        cell([
          for (final w in d.waste) entry('${w.kind.label}${who(w.who)}'),
          for (final c in d.chores) entry('${c.title}${who(c.who)}'),
        ]),
      ],
    );
  }

  pw.Widget choreBox(String heading, List<WeekPlanChore> chores) =>
      pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(top: 10),
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: line, width: 0.6),
          borderRadius: pw.BorderRadius.circular(6),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              heading,
              style: pw.TextStyle(font: bold, fontSize: 10, color: accent),
            ),
            pw.SizedBox(height: 3),
            pw.Wrap(
              spacing: 14,
              runSpacing: 2,
              children: [
                for (final c in chores) entry('${c.title}${who(c.who)}'),
              ],
            ),
          ],
        ),
      );

  final doc = pw.Document(title: tr.weekPlanTitle(range));
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(32, 32, 32, 28),
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          [
            tr.weekPlanMadeOn(DateFormat.yMd(appLanguage).format(today)),
            if (context.pagesCount > 1)
              '${context.pageNumber}/${context.pagesCount}',
          ].join(' · '),
          style: small,
        ),
      ),
      build: (context) => [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              tr.weekPlanHeading,
              style: pw.TextStyle(font: title, fontSize: 24, color: accent),
            ),
            pw.SizedBox(width: 12),
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 3),
              child: pw.Text(range, style: const pw.TextStyle(fontSize: 12)),
            ),
          ],
        ),
        pw.SizedBox(height: 10),
        pw.Table(
          border: pw.TableBorder.all(color: line, width: 0.6),
          columnWidths: const {
            0: pw.FixedColumnWidth(54),
            1: pw.FlexColumnWidth(3),
            2: pw.FlexColumnWidth(1.6),
            3: pw.FlexColumnWidth(1.7),
          },
          children: [
            pw.TableRow(
              repeat: true,
              decoration: pw.BoxDecoration(color: accent),
              children: [
                header(''),
                header(tr.weekPlanAppointments),
                header(tr.weekPlanMeals),
                header(tr.weekPlanChoresBins),
              ],
            ),
            for (final d in plan.days) row(d),
          ],
        ),
        if (plan.everyDay.isNotEmpty)
          choreBox(tr.weekPlanEveryDay, plan.everyDay),
        if (plan.weekly.isNotEmpty) choreBox(tr.weekPlanThisWeek, plan.weekly),
      ],
    ),
  );
  return doc.save();
}
