import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'app_icons.dart';

import 'palette.dart';
import '../l10n.dart';

/// Leaves enough width for seven 48 dp day targets on phones from 360 dp.
/// The range always includes [initialDate], so an older entry (a rent since
/// 2019, a task overdue for years) still opens on its own date.
Future<DateTime?> showFamioDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  String? helpText,
  DatePickerMode initialDatePickerMode = DatePickerMode.day,
}) {
  final (first, last) = datePickerRange(initialDate, firstDate, lastDate);
  return showDialog<DateTime>(
    context: context,
    builder: (_) => DatePickerDialog(
      initialDate: initialDate,
      firstDate: first,
      lastDate: last,
      helpText: helpText,
      initialCalendarMode: initialDatePickerMode,
      insetPadding: EdgeInsets.symmetric(
        horizontal: min(
          12.0,
          max(0.0, (MediaQuery.sizeOf(context).width - 360) / 2),
        ),
        vertical: 24,
      ),
    ),
  );
}

/// The bounds a date picker gets: widened so that [initial] (and, for a
/// range, [initialEnd]) lies inside, and never with the end before the start.
(DateTime, DateTime) datePickerRange(
  DateTime initial,
  DateTime first,
  DateTime last, [
  DateTime? initialEnd,
]) {
  final start = DateUtils.dateOnly(initial);
  final end = DateUtils.dateOnly(initialEnd ?? initial);
  var from = DateUtils.dateOnly(first);
  var to = DateUtils.dateOnly(last);
  if (start.isBefore(from)) from = start;
  if (end.isAfter(to)) to = end;
  if (to.isBefore(from)) from = to;
  return (from, to);
}

/// Page layout used by every section: a large friendly title on a soft
/// colored blob instead of a Material app bar.
class SectionPage extends StatelessWidget {
  const SectionPage({
    super.key,
    required this.section,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.floating,
    this.leading,
    this.bodyPadding = const EdgeInsets.symmetric(horizontal: 20),
    this.maxBodyWidth,
  });

  final FamioSection section;
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget body;
  final Widget? floating;
  final Widget? leading;
  final EdgeInsets bodyPadding;

  /// Lists and forms stay readable on wide screens: the body is centered
  /// with at most this width.
  final double? maxBodyWidth;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final canPop = Navigator.of(context).canPop();
    final titleStyle = Theme.of(context).textTheme.headlineMedium;
    var measured = DefaultTextStyle.of(context).style.merge(titleStyle);
    // Measured as Text draws it: with the system's bold text (iOS), wider.
    if (MediaQuery.boldTextOf(context)) {
      measured = measured.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final measure = TextPainter(
      text: TextSpan(text: title, style: measured),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final titleWidth = measure.width.ceilToDouble();
    measure.dispose();
    return Scaffold(
      backgroundColor: c.background,
      floatingActionButton: floating,
      body: Stack(
        children: [
          // Decorative blob in the section color behind the header.
          Positioned(
            top: -120,
            right: -80,
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                color: c.tint(section).withValues(alpha: c.dark ? 0.6 : 0.9),
                shape: BoxShape.circle,
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                  child: _HeaderRow(
                    titleWidth: titleWidth,
                    children: [
                      if (leading != null)
                        leading!
                      else if (canPop)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: BubbleButton(
                            icon: AppIcons.caretLeft,
                            tooltip: tr.commonBack,
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                        )
                      else
                        const SizedBox.shrink(),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: titleStyle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle!,
                              // Partly on the pastel circle behind it.
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: c.text(
                                      c.inkSoft,
                                      on: Color.alphaBlend(
                                        c
                                            .tint(section)
                                            .withValues(
                                              alpha: c.dark ? 0.6 : 0.9,
                                            ),
                                        c.background,
                                      ),
                                    ),
                                  ),
                              // Two lines on narrow phones, e.g. a
                              // child's age and birthday.
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final a in actions)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: a,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: bodyPadding,
                    child: maxBodyWidth == null
                        ? body
                        : Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: maxBodyWidth!,
                              ),
                              child: body,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Leading button, title column and actions of a [SectionPage] in one row.
/// When the title would be cut off next to the actions (narrow phones with
/// many buttons), the actions move to their own row below it.
class _HeaderRow extends MultiChildRenderObjectWidget {
  const _HeaderRow({required this.titleWidth, required super.children})
    : assert(children.length == 3);

  /// Width the title needs on one line.
  final double titleWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeaderRow(titleWidth);

  @override
  void updateRenderObject(BuildContext context, _RenderHeaderRow renderObject) {
    renderObject.titleWidth = titleWidth;
  }
}

class _HeaderParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderHeaderRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _HeaderParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _HeaderParentData> {
  _RenderHeaderRow(this._titleWidth);

  static const _rowGap = 8.0;

  double _titleWidth;
  set titleWidth(double value) {
    if (value == _titleWidth) return;
    _titleWidth = value;
    markNeedsLayout();
  }

  /// Whether the actions share the title's row in the last layout.
  bool oneRow = true;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _HeaderParentData) {
      child.parentData = _HeaderParentData();
    }
  }

  @override
  void performLayout() {
    final leading = firstChild!;
    final heading = childAfter(leading)!;
    final actions = childAfter(heading)!;
    final width = constraints.maxWidth;
    final loose = BoxConstraints(maxWidth: width);
    leading.layout(loose, parentUsesSize: true);
    actions.layout(loose, parentUsesSize: true);
    final lead = leading.size;
    final act = actions.size;
    oneRow =
        act.width == 0 ||
        !width.isFinite ||
        lead.width + _titleWidth + act.width <= width;
    final headWidth = max(0.0, width - lead.width - (oneRow ? act.width : 0));
    heading.layout(
      BoxConstraints.tightFor(width: headWidth),
      parentUsesSize: true,
    );
    final head = heading.size;
    final rowHeight = max(
      max(lead.height, head.height),
      oneRow ? act.height : 0.0,
    );
    Offset centered(Size s, double x) => Offset(x, (rowHeight - s.height) / 2);
    (leading.parentData! as BoxParentData).offset = centered(lead, 0);
    (heading.parentData! as BoxParentData).offset = centered(head, lead.width);
    (actions.parentData! as BoxParentData).offset = oneRow
        ? centered(act, width - act.width)
        : Offset(width - act.width, rowHeight + _rowGap);
    size = constraints.constrain(
      Size(width, oneRow ? rowHeight : rowHeight + _rowGap + act.height),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Round icon button on a soft background.
class BubbleButton extends StatelessWidget {
  const BubbleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
    this.background,
    // 48 × 48: the smallest comfortable tap target (Android guideline).
    this.size = 48,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;
  final Color? background;
  final double size;

  /// Smaller bubbles still get a tap target of this size around them.
  static const minTarget = 48.0;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final small = size < minTarget;
    // A white icon on a colored bubble: the bubble dark enough for 3:1.
    final background = this.background != null && color == Colors.white
        ? c.fill(this.background!, target: 3)
        : this.background;
    final icon = SizedBox.square(
      dimension: size,
      child: Icon(
        this.icon,
        size: size * 0.48,
        // White on a colored bubble follows the high-contrast mode.
        color: color == Colors.white && background != null
            ? c.onStrong
            : color ?? c.ink,
      ),
    );
    final bubble = Material(
      color: background ?? c.surface,
      shape: CircleBorder(
        side: background == null
            ? c.outline ?? BorderSide.none
            : BorderSide.none,
      ),
      shadowColor: c.shadow,
      elevation: background == null ? 2 : 0,
      child: small
          ? icon
          : InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: icon,
            ),
    );
    // A small bubble keeps its look, but the finger may hit around it.
    final button = small
        ? InkResponse(
            onTap: onPressed,
            radius: minTarget / 2,
            child: SizedBox.square(
              dimension: minTarget,
              child: Center(child: bubble),
            ),
          )
        : bubble;
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Rounded white card with a soft shadow, optionally tinted.
class SoftCard extends StatelessWidget {
  const SoftCard({
    super.key,
    required this.child,
    this.color,
    this.onTap,
    this.padding = const EdgeInsets.all(18),
    this.radius = 26,
  });

  final Widget child;
  final Color? color;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: color == null ? c.softShadow : null,
      ),
      child: Material(
        color: color ?? c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: c.outline ?? BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Icon in a colored circle – the app's replacement for plain list icons.
class IconBlob extends StatelessWidget {
  const IconBlob(
    this.icon, {
    super.key,
    required this.color,
    this.background,
    this.size = 44,
  });

  final IconData icon;
  final Color color;
  final Color? background;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: background ?? color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(size * 0.38),
    ),
    child: Icon(icon, color: color, size: size * 0.55),
  );
}

/// Big round tick box that pops when checked.
class RoundCheck extends StatelessWidget {
  const RoundCheck({
    super.key,
    required this.value,
    required this.onChanged,
    required this.color,
    this.label,
    this.size = 30,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color color;

  /// What is ticked off, read out by screen readers.
  final String? label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.readable(this.color);
    final onChanged = this.onChanged;
    return Semantics(
      checked: value,
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged == null ? null : () => onChanged(!value),
        child: Padding(
          // At least 48 × 48 to tap, however small the circle.
          padding: EdgeInsets.all(max(6, (48 - size) / 2)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: value ? color : Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(
                color: value
                    ? color
                    : c.inkSoft.withValues(alpha: c.highContrast ? 1 : 0.45),
                width: 2.5,
              ),
            ),
            child: AnimatedScale(
              scale: value ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              child: Icon(AppIcons.check, size: size * 0.55, color: c.onStrong),
            ),
          ),
        ),
      ),
    );
  }
}

/// Friendly empty state with a big icon.
class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
    this.action,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconBlob(icon, color: color, size: 88),
          const SizedBox(height: 18),
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    ),
  );
}

/// Pill-shaped filter chips, replacing Material's segmented button.
class PillTabs<T> extends StatelessWidget {
  const PillTabs({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onChanged,
    required this.color,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // Room for the chip shadows, which a scroll view would clip.
        padding: const EdgeInsets.only(bottom: 6),
        clipBehavior: Clip.none,
        child: Row(
          children: [
            for (final v in values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => onChanged(v),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: v == selected ? c.fill(color) : c.surface,
                      borderRadius: BorderRadius.circular(40),
                      border: v == selected || c.outline == null
                          ? null
                          : Border.fromBorderSide(c.outline!),
                      boxShadow: v == selected ? null : c.softShadow,
                    ),
                    child: Text(
                      label(v),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: v == selected ? c.onStrong : c.ink,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Section heading inside lists.
class ListHeading extends StatelessWidget {
  const ListHeading(this.text, {super.key, this.color, this.trailing});

  final String text;
  final Color? color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: FamioColors.of(
                context,
              ).text(color ?? FamioColors.of(context).inkSoft),
              letterSpacing: 0.3,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// Primary action button in a section color.
class ColorButton extends StatelessWidget {
  const ColorButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.color,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: FamioColors.of(context).fill(color),
      foregroundColor: FamioColors.of(context).onStrong,
    );
    return icon == null
        ? FilledButton(style: style, onPressed: onPressed, child: Text(label))
        : FilledButton.icon(
            style: style,
            onPressed: onPressed,
            icon: Icon(icon, size: 20),
            label: Text(label),
          );
  }
}

/// Floating "add" button in a section color.
class AddButton extends StatelessWidget {
  const AddButton({
    super.key,
    required this.color,
    required this.onPressed,
    required this.tooltip,
    this.icon = AppIcons.plus,
  });

  final Color color;
  final VoidCallback onPressed;
  final String tooltip;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
    // Stay clear of the floating navigation bar and the iPhone home
    // indicator. The inner section Scaffold does not know about the shell's
    // floating navigation bar.
    padding: EdgeInsets.only(bottom: floatingNavigationClearance(context)),
    child: FloatingActionButton(
      heroTag: null,
      tooltip: tooltip,
      // White icon alone: 3:1 suffices (WCAG 1.4.11).
      backgroundColor: FamioColors.of(context).fill(color, target: 3),
      foregroundColor: FamioColors.of(context).onStrong,
      onPressed: onPressed,
      child: Icon(icon, size: 28),
    ),
  );
}

/// Vertical clearance for a floating action above the phone navigation bar.
///
/// [viewPadding] retains the iPhone home-indicator inset while a keyboard is
/// open, unlike the effective [MediaQuery.padding].
double floatingNavigationClearance(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 720
    ? 96 + MediaQuery.viewPaddingOf(context).bottom
    : 0;

/// Bottom padding so the last list item is not hidden behind the
/// floating navigation bar and add button.
double listBottomPadding(BuildContext context) =>
    (MediaQuery.sizeOf(context).width < 720
        ? 192 + MediaQuery.viewPaddingOf(context).bottom
        : 100) +
    TipInset.of(context);

/// Space a section's tip takes above the bottom of the page (see HomeShell):
/// lists add it below their last entry. The add button stays where it is,
/// between the navigation bar and the tip.
class TipInset extends InheritedWidget {
  const TipInset({super.key, required this.height, required super.child});

  final double height;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TipInset>()?.height ?? 0;

  @override
  bool updateShouldNotify(TipInset old) => old.height != height;
}
