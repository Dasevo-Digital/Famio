part of '../kids_screens.dart';

class _GrowthView extends StatelessWidget {
  const _GrowthView({
    required this.child,
    required this.entries,
    required this.color,
  });

  final Child child;
  final List<ChildEntry> entries;
  final Color color;

  /// Age in months with fractions (for the WHO curves).
  double _age(DateTime d) => d.difference(child.birthDate).inDays / 30.4375;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Measurements, also those taken at check-ups.
    final measured = entries
        .where(
          (e) => e.heightCm != null || e.weightKg != null || e.headCm != null,
        )
        .toList();
    List<(double, double)> series(double? Function(ChildEntry) value) => [
      for (final e in measured)
        if (value(e) != null && !e.dateUnknown) (_age(e.date), value(e)!),
    ];
    final charts = [
      (
        tr.kidsHeightCm,
        GrowthMeasure.length,
        series((e) => e.heightCm),
        const Color(0xFF3587D6),
      ),
      (
        tr.kidsWeightKg,
        GrowthMeasure.weight,
        series((e) => e.weightKg),
        const Color(0xFFE8703A),
      ),
      (
        tr.growthHeadCircumferenceCm,
        GrowthMeasure.head,
        series((e) => e.headCm),
        const Color(0xFF7B5BE0),
      ),
    ];
    final sex = child.sex;
    return ListView(
      padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: ColorButton(
            label: tr.growthAddMeasurement,
            icon: AppIcons.ruler,
            color: const Color(0xFF2A9D6E),
            onPressed: () => showEntryEditor(
              context,
              child: child,
              kind: ChildEntryKind.measurement,
            ),
          ),
        ),
        const SizedBox(height: 12),
        for (final (title, measure, points, lineColor) in charts)
          if (points.length >= 2 ||
              (points.isNotEmpty && sex != null && points.last.$1 <= 24)) ...[
            _ChartCard(
              title: title,
              points: points,
              color: lineColor,
              reference: sex == null
                  ? null
                  : (x) => growthReference(sex, measure, x),
              percentile: sex == null || points.isEmpty
                  ? null
                  : () {
                      final (x, y) = points.reduce(
                        (a, b) => a.$1 > b.$1 ? a : b,
                      );
                      final lms = growthReference(sex, measure, x);
                      return lms == null ? null : growthPercentile(lms, y);
                    }(),
            ),
            const SizedBox(height: 12),
          ],
        if (charts.every((c) => c.$3.length < 2))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              tr.growthCurveAppearsHereTwo,
              style: theme.textTheme.bodySmall,
            ),
          ),
        Text(
          sex == null
              ? tr.growthGenderProfileFamioShows
              : tr.growthGrayWhoGrowthStandards,
          style: theme.textTheme.bodySmall,
        ),
        ListHeading(tr.growthAllMeasurements),
        for (final e in measured.reversed)
          ListTile(
            leading: Icon(
              e.kind == ChildEntryKind.checkup
                  ? AppIcons.stethoscope
                  : AppIcons.ruler,
            ),
            title: Text(
              [
                if (e.heightCm != null) '${_num(e.heightCm!)} cm',
                if (e.weightKg != null) '${_num(e.weightKg!)} kg',
                if (e.headCm != null) tr.kidsHeadSizeCm(_num(e.headCm!)),
              ].join(' · '),
            ),
            subtitle: Text(
              [
                if (e.kind == ChildEntryKind.checkup)
                  checkupById(e.refId)?.id ?? tr.kidsTabCheckups,
                e.dateUnknown ? tr.kidsDateUnknown : _date.format(e.date),
                if (!e.dateUnknown) tr.growthAge(ageLabel(child, e.date)),
              ].join(' · '),
            ),
            onTap: () => showEntryEditor(
              context,
              child: child,
              kind: e.kind,
              existing: e,
            ),
          ),
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.points,
    required this.color,
    this.reference,
    this.percentile,
  });

  final String title;
  final List<(double, double)> points;
  final Color color;

  /// WHO reference at an age in months (null outside 0–24).
  final Lms? Function(double months)? reference;

  /// Percentile of the latest value.
  final double? percentile;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final xs = points.map((p) => p.$1);
    final minX = math.max(0.0, xs.reduce(math.min) - 1).floorToDouble();
    final maxX = math.max(xs.reduce(math.max) + 1, minX + 3).ceilToDouble();
    final bands = <(double, double, double, double)>[];
    if (reference != null) {
      for (var x = minX; x <= maxX + 0.01; x += 0.5) {
        final lms = reference!(x);
        if (lms != null) {
          bands.add((
            x,
            lms.valueAt(-1.881),
            lms.valueAt(0),
            lms.valueAt(1.881),
          ));
        }
      }
    }
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (percentile != null)
                Text(
                  tr.growthPercentileValue(percentile!.round().clamp(1, 99)),
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: color),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 170,
            child: CustomPaint(
              size: Size.infinite,
              painter: _LinePainter(
                points: points,
                color: color,
                grid: c.line,
                label: c.inkSoft,
                bands: bands,
                minX: bands.isEmpty ? null : minX,
                maxX: bands.isEmpty ? null : maxX,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.points,
    required this.color,
    required this.grid,
    required this.label,
    this.bands = const [],
    this.minX,
    this.maxX,
  });

  final List<(double, double)> points;
  final Color color;
  final Color grid;
  final Color label;

  /// Reference curves: (age, P3, P50, P97).
  final List<(double, double, double, double)> bands;
  final double? minX;
  final double? maxX;

  @override
  void paint(Canvas canvas, Size size) {
    final sorted = [...points]..sort((a, b) => a.$1.compareTo(b.$1));
    final x0 = minX ?? sorted.first.$1;
    final x1 = maxX ?? math.max(sorted.last.$1, sorted.first.$1 + 1);
    final ys = [
      ...sorted.map((p) => p.$2),
      for (final b in bands) ...[b.$2, b.$4],
    ];
    final minY = ys.reduce(math.min) * 0.95, maxY = ys.reduce(math.max) * 1.05;
    const left = 36.0, bottom = 20.0;
    Offset at((double, double) p) => Offset(
      left + (p.$1 - x0) / (x1 - x0) * (size.width - left - 8),
      (size.height - bottom) -
          (p.$2 - minY) / (maxY - minY) * (size.height - bottom - 8),
    );
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1.5;
    final text = TextStyle(
      color: label,
      fontFamily: bodyFont,
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
    );
    for (var i = 0; i <= 3; i++) {
      final y = (size.height - bottom) * i / 3 + 4;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), gridPaint);
      final value = maxY - (maxY - minY) * i / 3;
      (TextPainter(
        text: TextSpan(text: _num(value), style: text),
        textDirection: TextDirection.ltr,
      )..layout()).paint(canvas, Offset(0, y - 7));
    }
    for (final x in [x0, x1]) {
      (TextPainter(
        text: TextSpan(text: _months(x), style: text),
        textDirection: TextDirection.ltr,
      )..layout()).paint(
        canvas,
        Offset(at((x, minY)).dx - 12, size.height - 14),
      );
    }
    if (bands.length >= 2) {
      final area = Path()
        ..moveTo(
          at((bands.first.$1, bands.first.$2)).dx,
          at((bands.first.$1, bands.first.$2)).dy,
        );
      for (final b in bands.skip(1)) {
        area.lineTo(at((b.$1, b.$2)).dx, at((b.$1, b.$2)).dy);
      }
      for (final b in bands.reversed) {
        area.lineTo(at((b.$1, b.$4)).dx, at((b.$1, b.$4)).dy);
      }
      area.close();
      canvas.drawPath(area, Paint()..color = label.withValues(alpha: 0.10));
      final median = Path()
        ..moveTo(
          at((bands.first.$1, bands.first.$3)).dx,
          at((bands.first.$1, bands.first.$3)).dy,
        );
      for (final b in bands.skip(1)) {
        median.lineTo(at((b.$1, b.$3)).dx, at((b.$1, b.$3)).dy);
      }
      canvas.drawPath(
        median,
        Paint()
          ..color = label.withValues(alpha: 0.45)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
    }
    final path = Path()..moveTo(at(sorted.first).dx, at(sorted.first).dy);
    for (final p in sorted.skip(1)) {
      path.lineTo(at(p).dx, at(p).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 3.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    for (final p in sorted) {
      canvas.drawCircle(at(p), 5, Paint()..color = color);
      canvas.drawCircle(at(p), 2.5, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.points != points || old.color != color || old.bands != bands;
}

// --- editors -----------------------------------------------------------------
