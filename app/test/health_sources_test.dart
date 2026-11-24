import 'package:famio/src/screens/health_sources_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The health content names its sources with their dates (#527).
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('the sources page lists each area with its date', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HealthSourcesScreen()));
    for (final text in [
      'Impfungen und RSV',
      'Vorsorge-Untersuchungen und Stuhlfarbe',
      'Fieber',
      'RKI, 22.01.2026',
      'G-BA, Juni 2026',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    await tester.scrollUntilVisible(
      find.text('Mutterschafts-Richtlinien'),
      200,
    );
    expect(find.text('Mutterschafts-Richtlinien'), findsOneWidget);
    // The rules behind the Austrian school-free days and the Swiss
    // cantons that differ from the federal list (#596).
    for (final text in [
      'Kärntner Schulgesetz, § 74 Schuljahr für Pflichtschulen',
      'Feiertage im Kanton Freiburg',
      'Einführungsgesetz zum Arbeitsrecht, § 6 Kantonale Feiertage',
    ]) {
      await tester.scrollUntilVisible(find.text(text), 200);
      expect(find.text(text), findsOneWidget, reason: text);
    }
  });
}
