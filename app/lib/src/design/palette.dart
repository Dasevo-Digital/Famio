import 'package:flutter/material.dart';
import 'app_icons.dart';

/// The app's areas. Each has its own pastel color and icon, so children
/// (and tired parents) find their way by color.
enum FamioSection {
  home('Start', AppIcons.house, Color(0xFFFFEDB3), Color(0xFFE89B1A)),
  tasks(
    'Aufgaben',
    AppIcons.checkSquareOffset,
    Color(0xFFC9F0DD),
    Color(0xFF2A9D6E),
  ),
  shopping('Einkauf', AppIcons.basket, Color(0xFFFFDCC8), Color(0xFFE8703A)),
  calendar(
    'Kalender',
    AppIcons.calendarHeart,
    Color(0xFFE4DAFF),
    Color(0xFF7B5BE0),
  ),
  chat('Chat', AppIcons.chatsCircle, Color(0xFFD3EBFF), Color(0xFF3587D6)),
  documents(
    'Dokumente',
    AppIcons.folderSimpleStar,
    Color(0xFFF4E4CF),
    Color(0xFFB07A3C),
  ),
  kids('Kinder', AppIcons.baby, Color(0xFFFFD6E4), Color(0xFFDB4A7E)),
  location(
    'Standort',
    AppIcons.mapPinned,
    Color(0xFFCCEFEA),
    Color(0xFF16927F),
  ),
  meals('Essen', AppIcons.cookingPot, Color(0xFFE6F2C4), Color(0xFF6E8F12)),
  budget('Finanzen', AppIcons.wallet, Color(0xFFD9F0E4), Color(0xFF1F8A5B)),
  contacts('Kontakte', AppIcons.bookUser, Color(0xFFDDE3FF), Color(0xFF4F5BD5)),
  settings(
    'Einstellungen',
    AppIcons.gearSix,
    Color(0xFFE6E8F0),
    Color(0xFF636A8A),
  );

  const FamioSection(this.label, this.icon, this.tint, this.strong);

  final String label;
  final IconData icon;

  /// Soft background color (light mode).
  final Color tint;

  /// Saturated accent for icons, buttons and selection.
  final Color strong;
}

/// Neutral colors of the design, available via `FamioColors.of(context)`.
@immutable
class FamioColors extends ThemeExtension<FamioColors> {
  const FamioColors({
    required this.background,
    required this.surface,
    required this.surfaceSoft,
    required this.ink,
    required this.inkSoft,
    required this.line,
    required this.shadow,
    required this.dark,
  });

  static const light = FamioColors(
    background: Color(0xFFFFF8F1),
    surface: Colors.white,
    surfaceSoft: Color(0xFFFFF0E3),
    ink: Color(0xFF2D3150),
    inkSoft: Color(0xFF6E7393),
    line: Color(0xFFF0E5DA),
    shadow: Color(0x1A8A5A3C),
    dark: false,
  );

  static const darkColors = FamioColors(
    background: Color(0xFF1B1D2B),
    surface: Color(0xFF262A3D),
    surfaceSoft: Color(0xFF30354F),
    ink: Color(0xFFF4F1FA),
    inkSoft: Color(0xFFA9ADC6),
    line: Color(0xFF383E5A),
    shadow: Color(0x40000000),
    dark: true,
  );

  final Color background;
  final Color surface;
  final Color surfaceSoft;
  final Color ink;
  final Color inkSoft;
  final Color line;
  final Color shadow;
  final bool dark;

  static FamioColors of(BuildContext context) =>
      Theme.of(context).extension<FamioColors>()!;

  /// Background tint of [section], toned down in dark mode.
  Color tint(FamioSection section) => dark
      ? Color.alphaBlend(section.strong.withValues(alpha: 0.22), surface)
      : section.tint;

  /// Accent of [section], slightly brighter in dark mode for contrast.
  Color strong(FamioSection section) =>
      dark ? Color.lerp(section.strong, Colors.white, 0.18)! : section.strong;

  /// Destructive actions and errors, in a friendly red.
  Color get danger => dark ? const Color(0xFFFF8F8F) : const Color(0xFFD64545);

  List<BoxShadow> get softShadow => [
    BoxShadow(color: shadow, blurRadius: 24, offset: const Offset(0, 8)),
  ];

  @override
  FamioColors copyWith() => this;

  @override
  FamioColors lerp(FamioColors? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

/// Colors for people and categories picked by users.
const famioPalette = [
  0xFF3587D6,
  0xFFE8703A,
  0xFF2A9D6E,
  0xFFDB4A7E,
  0xFF7B5BE0,
  0xFFE89B1A,
  0xFF1AA3A3,
  0xFFB07A3C,
];
