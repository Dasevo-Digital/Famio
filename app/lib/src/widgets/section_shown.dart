import 'package:flutter/widgets.dart';

/// Whether the section around a page is what is on screen: its tab is the
/// chosen one and nothing covers the whole app, such as a dialog on the
/// app's own navigator. [TickerMode] only tells the first, and the route of
/// a page inside a section does not know about the app's navigator (#400).
class SectionShown extends InheritedWidget {
  const SectionShown({super.key, required this.shown, required super.child});

  final bool shown;

  /// True outside a section (a page on the app's own navigator).
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SectionShown>()?.shown ?? true;

  @override
  bool updateShouldNotify(SectionShown oldWidget) => oldWidget.shown != shown;
}
