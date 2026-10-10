import 'package:flutter/material.dart';

import 'palette.dart';

const bodyFont = 'Nunito';
const displayFont = 'Fredoka';

/// The Famio look: warm pastel surfaces, rounded shapes, playful headings.
/// Deliberately avoids stock Material cues (ripples, Roboto, sharp app bars).
///
/// [highContrast] keeps the look but makes all text reach WCAG AA contrast.
ThemeData famioTheme(Brightness brightness, {bool highContrast = false}) {
  final base = brightness == Brightness.dark
      ? FamioColors.darkColors
      : FamioColors.light;
  final c = highContrast ? base.withHighContrast() : base;
  final accent = c.strong(FamioSection.calendar);
  // Material uses primary for text (text buttons, labels) and as a fill
  // behind onPrimary: the text tone, with dark text on it where white
  // would not be readable (dark mode).
  Color on(Color fill) =>
      FamioColors.contrast(Colors.white, fill) >= FamioColors.textTarget
      ? Colors.white
      : const Color(0xFF12131C);
  final primary = c.text(accent);
  final secondary = c.sectionText(FamioSection.tasks);
  final tertiary = c.sectionText(FamioSection.kids);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: primary,
    onPrimary: highContrast ? c.onStrong : on(primary),
    primaryContainer: c.tint(FamioSection.calendar),
    onPrimaryContainer: c.ink,
    secondary: secondary,
    onSecondary: highContrast ? c.onStrong : on(secondary),
    secondaryContainer: c.tint(FamioSection.tasks),
    onSecondaryContainer: c.ink,
    tertiary: tertiary,
    onTertiary: highContrast ? c.onStrong : on(tertiary),
    error: c.readable(const Color(0xFFE0485B), on: const Color(0xFFFBE7EA)),
    onError: Colors.white,
    errorContainer: const Color(0xFFFFDDE1),
    onErrorContainer: const Color(0xFF7A1422),
    surface: c.surface,
    onSurface: c.ink,
    surfaceContainerLowest: c.surface,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surfaceSoft,
    surfaceContainerHigh: c.surfaceSoft,
    surfaceContainerHighest: c.surfaceSoft,
    onSurfaceVariant: c.inkSoft,
    outline: c.inkSoft,
    outlineVariant: c.line,
    shadow: c.shadow,
  );

  TextStyle display(double size, [FontWeight weight = FontWeight.w600]) =>
      TextStyle(
        fontFamily: displayFont,
        fontSize: size,
        fontWeight: weight,
        color: c.ink,
        height: 1.15,
      );
  TextStyle body(double size, [FontWeight weight = FontWeight.w600]) =>
      TextStyle(
        fontFamily: bodyFont,
        fontSize: size,
        fontWeight: weight,
        color: c.ink,
      );

  final textTheme = TextTheme(
    displaySmall: display(34),
    headlineLarge: display(30),
    headlineMedium: display(26),
    headlineSmall: display(22),
    titleLarge: display(20),
    titleMedium: body(16, FontWeight.w800),
    titleSmall: body(14, FontWeight.w800),
    bodyLarge: body(16),
    bodyMedium: body(14),
    bodySmall: body(12.5).copyWith(color: c.inkSoft),
    labelLarge: body(15, FontWeight.w800),
    labelMedium: body(13, FontWeight.w700),
    labelSmall: body(11.5, FontWeight.w700),
  );

  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(18));
  final soft = RoundedRectangleBorder(borderRadius: BorderRadius.circular(24));
  const padding = EdgeInsets.symmetric(horizontal: 22, vertical: 14);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: bodyFont,
    textTheme: textTheme,
    scaffoldBackgroundColor: c.background,
    canvasColor: c.background,
    extensions: [c],
    // No ink ripples: a quiet color change feels less "Android".
    splashFactory: NoSplash.splashFactory,
    highlightColor: c.ink.withValues(alpha: 0.04),
    hoverColor: c.ink.withValues(alpha: 0.03),
    focusColor: accent.withValues(alpha: 0.12),
    visualDensity: VisualDensity.standard,
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final p in TargetPlatform.values) p: const _SoftPageTransition(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: display(22),
      foregroundColor: c.ink,
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      shape: soft,
      margin: EdgeInsets.zero,
    ),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1.5, space: 1.5),
    iconTheme: IconThemeData(color: c.ink, size: 24),
    listTileTheme: ListTileThemeData(
      shape: pill,
      iconColor: c.inkSoft,
      titleTextStyle: body(16, FontWeight.w700),
      subtitleTextStyle: body(13, FontWeight.w600).copyWith(color: c.inkSoft),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surfaceSoft,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: accent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      labelStyle: body(15).copyWith(color: c.inkSoft),
      floatingLabelStyle: body(14, FontWeight.w800).copyWith(color: primary),
      hintStyle: body(15).copyWith(color: c.inkSoft.withValues(alpha: 0.8)),
      prefixIconColor: c.inkSoft,
      suffixIconColor: c.inkSoft,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: pill,
        padding: padding,
        textStyle: textTheme.labelLarge,
        elevation: 0,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: pill,
        padding: padding,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: pill,
        padding: padding,
        side: BorderSide(color: c.line, width: 2),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: pill,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: textTheme.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(shape: pill),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      side: BorderSide(color: c.inkSoft.withValues(alpha: 0.5), width: 2),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? accent : c.line,
      ),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: c.surfaceSoft,
      selectedColor: c.tint(FamioSection.calendar),
      labelStyle: body(14, FontWeight.w700),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      showCheckmark: false,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: display(22),
      contentTextStyle: body(15),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: c.line,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.ink,
      contentTextStyle: body(14, FontWeight.w700).copyWith(color: c.background),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      elevation: 0,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      textStyle: body(15, FontWeight.w700),
      elevation: 6,
      shadowColor: c.shadow,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.ink,
        borderRadius: BorderRadius.circular(12),
      ),
      textStyle: body(12.5, FontWeight.w700).copyWith(color: c.background),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: c.line,
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      headerHeadlineStyle: display(26),
      dayShape: const WidgetStatePropertyAll(CircleBorder()),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      hourMinuteShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: c.inkSoft,
      collapsedIconColor: c.inkSoft,
    ),
  );
}

/// Pages fade in while gliding up a little – gentler than platform defaults.
class _SoftPageTransition extends PageTransitionsBuilder {
  const _SoftPageTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// Bouncy scrolling everywhere, no Android glow or stretch.
class FamioScrollBehavior extends MaterialScrollBehavior {
  const FamioScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
