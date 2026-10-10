import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../app_state.dart';
import '../data/year_review.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/files.dart';
import '../l10n.dart';

const _collections = {
  Collections.events,
  Collections.tasks,
  Collections.pointEntries,
  Collections.chatMessages,
  Collections.mealPlan,
  Collections.children,
  Collections.childEntries,
  'members',
};

/// The year in review: numbers, the children's milestones, trips, photos
/// from the chat and the chores, also as a PDF to keep or share.
class YearReviewScreen extends StatefulWidget {
  const YearReviewScreen({super.key, this.year});

  final int? year;

  @override
  State<YearReviewScreen> createState() => _YearReviewScreenState();
}

class _YearReviewScreenState extends State<YearReviewScreen> {
  late var _year = widget.year ?? reviewYear(DateTime.now());
  var _saving = false;

  Future<void> _savePdf(YearReview review) async {
    final messenger = ScaffoldMessenger.of(context);
    final files = AppScope.read(context).files;
    setState(() => _saving = true);
    try {
      final bytes = await yearReviewPdf(review, files: files);
      final saved = await FilePicker.saveFile(
        dialogTitle: tr.yearReviewPdf,
        fileName: 'famio-${review.year}.pdf',
        bytes: bytes,
        mimeType: 'application/pdf',
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            saved == null ? tr.yearReviewNotSaved : tr.yearReviewSaved,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = FamioColors.of(context).strong(FamioSection.home);
    final latest = DateTime.now().year;
    return DataBuilder(
      collections: _collections,
      builder: (context, engine) {
        final review = yearReview(engine, _year);
        final date = DateFormat.MMMd(appLanguage);
        return SectionPage(
          section: FamioSection.home,
          title: tr.yearReviewTitle(_year),
          actions: [
            BubbleButton(
              icon: AppIcons.caretLeft,
              tooltip: tr.yearReviewPrevious,
              onPressed: () => setState(() => _year--),
            ),
            const SizedBox(width: 8),
            BubbleButton(
              icon: AppIcons.caretRight,
              tooltip: tr.yearReviewNext,
              onPressed: _year >= latest ? null : () => setState(() => _year++),
            ),
            const SizedBox(width: 8),
            BubbleButton(
              icon: AppIcons.fileText,
              tooltip: tr.yearReviewPdf,
              onPressed: _saving || review.isEmpty
                  ? null
                  : () => _savePdf(review),
            ),
          ],
          body: review.isEmpty
              ? EmptyHint(
                  icon: AppIcons.sparkle,
                  color: color,
                  text: tr.yearReviewEmpty(_year),
                )
              : ListView(
                  padding: EdgeInsets.only(bottom: listBottomPadding(context)),
                  children: [
                    ListHeading(tr.yearReviewNumbers),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final (value, label) in _numbers(review))
                          SizedBox(
                            width: 150,
                            child: SoftCard(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    NumberFormat.decimalPattern(
                                      appLanguage,
                                    ).format(value),
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(
                                          color: FamioColors.of(
                                            context,
                                          ).text(color),
                                        ),
                                  ),
                                  Text(label),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (review.kids.any(_hasNews)) ...[
                      ListHeading(tr.yearReviewKids),
                      for (final k in review.kids.where(_hasNews))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: SoftCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  [
                                    k.child.name,
                                    if (k.grownCm case final cm?)
                                      tr.yearReviewGrown(_cm(cm)),
                                  ].join(' · '),
                                  style: theme.textTheme.titleMedium,
                                ),
                                for (final m in k.milestones) Text('• $m'),
                              ],
                            ),
                          ),
                        ),
                    ],
                    if (review.trips.isNotEmpty) ...[
                      ListHeading(tr.yearReviewTrips),
                      for (final t in review.trips)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(AppIcons.mapPin, color: color),
                          title: Text(t.title),
                          subtitle: Text(_span(date, t)),
                        ),
                    ],
                    if (review.photos.isNotEmpty) ...[
                      ListHeading(tr.yearReviewPhotos),
                      GridView.count(
                        crossAxisCount: 3,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        children: [
                          for (final p in review.photos)
                            CachedImage(p, thumb: 480, radius: 14),
                        ],
                      ),
                    ],
                    if (review.chores.isNotEmpty) ...[
                      ListHeading(tr.yearReviewChoreChampions),
                      for (final c in review.chores.take(5))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(c.member.displayName),
                          trailing: Text(
                            '${c.count}',
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

bool _hasNews(ReviewChild k) => k.milestones.isNotEmpty || k.grownCm != null;

String _cm(double cm) =>
    NumberFormat.decimalPattern(appLanguage).format((cm * 10).round() / 10);

/// "12. Aug. – 26. Aug." (all-day ends are exclusive).
String _span(DateFormat date, ReviewTrip t) {
  final last = t.end.subtract(const Duration(days: 1));
  return last.isAfter(t.start)
      ? '${date.format(t.start)} – ${date.format(last)}'
      : date.format(t.start);
}

List<(int, String)> _numbers(YearReview r) => [
  (r.events, tr.yearReviewEvents),
  if (r.tasksDone > 0) (r.tasksDone, tr.yearReviewTasks),
  if (r.choresDone > 0) (r.choresDone, tr.yearReviewChores),
  if (r.messages > 0) (r.messages, tr.yearReviewMessages),
  if (r.photoCount > 0) (r.photoCount, tr.yearReviewPhotos),
  if (r.meals > 0) (r.meals, tr.yearReviewMeals),
];

/// The review as an A4 PDF in Famio's fonts; photos as far as [files] can
/// load them (the others are left out).
Future<Uint8List> yearReviewPdf(YearReview review, {FileCache? files}) async {
  Future<pw.Font> font(String name) async =>
      pw.Font.ttf(await rootBundle.load('assets/fonts/$name.ttf'));
  final regular = await font('Nunito-400');
  final bold = await font('Nunito-800');
  final title = await font('Fredoka-600');
  final accent = PdfColor.fromInt(
    FamioColors.light.sectionText(FamioSection.home).toARGB32(),
  );
  final images = <pw.MemoryImage>[];
  for (final p in review.photos) {
    try {
      final bytes = await files?.bytes(p, thumb: 640);
      if (bytes != null) images.add(pw.MemoryImage(bytes));
    } on Object {
      // Offline or gone: without it.
    }
  }
  final date = DateFormat.MMMd(appLanguage);
  final number = NumberFormat.decimalPattern(appLanguage);
  pw.Widget heading(String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 18, bottom: 6),
    child: pw.Text(
      text,
      style: pw.TextStyle(font: title, fontSize: 16, color: accent),
    ),
  );

  final doc = pw.Document(title: tr.yearReviewTitle(review.year));
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          '${tr.yearReviewMadeWith} · ${context.pageNumber}/${context.pagesCount}',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
        ),
      ),
      build: (context) => [
        pw.Text(
          tr.yearReviewTitle(review.year),
          style: pw.TextStyle(font: title, fontSize: 28, color: accent),
        ),
        heading(tr.yearReviewNumbers),
        pw.Wrap(
          spacing: 16,
          runSpacing: 10,
          children: [
            for (final (value, label) in _numbers(review))
              pw.SizedBox(
                width: 150,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      number.format(value),
                      style: pw.TextStyle(font: bold, fontSize: 20),
                    ),
                    pw.Text(label),
                  ],
                ),
              ),
          ],
        ),
        if (review.kids.any(_hasNews)) ...[
          heading(tr.yearReviewKids),
          for (final k in review.kids.where(_hasNews)) ...[
            pw.Text(
              [
                k.child.name,
                if (k.grownCm case final cm?) tr.yearReviewGrown(_cm(cm)),
              ].join(' · '),
              style: pw.TextStyle(font: bold, fontSize: 13),
            ),
            for (final m in k.milestones) pw.Bullet(text: m),
            pw.SizedBox(height: 6),
          ],
        ],
        if (review.trips.isNotEmpty) ...[
          heading(tr.yearReviewTrips),
          for (final t in review.trips)
            pw.Bullet(text: '${t.title} · ${_span(date, t)}'),
        ],
        if (images.isNotEmpty) ...[
          heading(tr.yearReviewPhotos),
          pw.GridView(
            crossAxisCount: 3,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            children: [
              for (final image in images)
                pw.Image(image, fit: pw.BoxFit.cover, height: 150),
            ],
          ),
        ],
        if (review.chores.isNotEmpty) ...[
          heading(tr.yearReviewChoreChampions),
          for (final c in review.chores.take(5))
            pw.Bullet(text: '${c.member.displayName}: ${c.count}'),
        ],
      ],
    ),
  );
  return doc.save();
}
