import 'package:famio/src/design/palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final base in [FamioColors.light, FamioColors.darkColors]) {
    final mode = base.dark ? 'dark' : 'light';

    test('$mode: pastel look stays unchanged without the switch', () {
      for (final s in FamioSection.values) {
        expect(
          base.strong(s),
          base.dark ? Color.lerp(s.strong, Colors.white, 0.18) : s.strong,
        );
      }
      expect(base.onStrong, Colors.white);
    });

    test('$mode: every section color reaches 4.5:1 with high contrast', () {
      final c = base.withHighContrast();
      for (final s in FamioSection.values) {
        final strong = c.strong(s);
        for (final ground in [c.background, c.surface, c.tint(s)]) {
          expect(
            FamioColors.contrast(strong, ground),
            greaterThanOrEqualTo(FamioColors.contrastTarget),
            reason: '${s.label} on $ground',
          );
        }
        expect(
          FamioColors.contrast(c.onStrong, strong),
          greaterThanOrEqualTo(FamioColors.contrastTarget),
          reason: 'text on ${s.label}',
        );
      }
      for (final ground in [c.background, c.surface, c.surfaceSoft]) {
        expect(
          FamioColors.contrast(c.inkSoft, ground),
          greaterThanOrEqualTo(FamioColors.contrastTarget),
        );
      }
    });
  }

  test('outlines only with high contrast, at least 3:1', () {
    expect(FamioColors.light.outline, isNull);
    for (final c in [
      FamioColors.light.withHighContrast(),
      FamioColors.darkColors.withHighContrast(),
    ]) {
      expect(
        FamioColors.contrast(c.outline!.color, c.background),
        greaterThanOrEqualTo(3),
      );
    }
  });

  for (final base in [FamioColors.light, FamioColors.darkColors]) {
    final mode = base.dark ? 'dark' : 'light';

    test('$mode: text and fill tones of every section reach AA', () {
      for (final s in FamioSection.values) {
        final text = base.sectionText(s);
        for (final ground in [
          base.background,
          base.surface,
          base.surfaceSoft,
        ]) {
          expect(
            FamioColors.contrast(text, ground),
            greaterThanOrEqualTo(FamioColors.textTarget),
            reason: '${s.name} text',
          );
        }
        final fill = base.fill(base.strong(s));
        expect(
          FamioColors.contrast(base.onStrong, fill),
          greaterThanOrEqualTo(FamioColors.textTarget),
          reason: '${s.name} fill',
        );
        expect(
          FamioColors.contrast(
            base.onStrong,
            base.fill(base.strong(s), target: 3),
          ),
          greaterThanOrEqualTo(3),
        );
      }
    });

    test('$mode: tones darken only as far as needed', () {
      // Already readable: unchanged.
      expect(base.text(base.ink), base.ink);
      expect(
        base.sectionText(FamioSection.contacts),
        base.dark
            ? isNot(base.strong(FamioSection.contacts))
            : base.strong(FamioSection.contacts),
      );
      // Start (orange) needs it most, but stays orange-ish, not black.
      final start = base.sectionText(FamioSection.home);
      expect(start, isNot(base.dark ? Colors.white : Colors.black));
      final hsl = HSLColor.fromColor(start);
      expect(
        hsl.hue,
        closeTo(HSLColor.fromColor(FamioSection.home.strong).hue, 4),
      );
    });
  }
}
