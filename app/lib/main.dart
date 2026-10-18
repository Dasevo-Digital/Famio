import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'src/app.dart';
import 'src/app_state.dart';
import 'src/screens/deferred_sections.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Dates in every language the app speaks (AppState.init picks one).
  await initializeDateFormatting();
  // Fonts that ship with the app are no Dart packages: their licenses
  // join the license page by hand.
  LicenseRegistry.addLicense(() async* {
    for (final (name, file) in const [
      ('Lucide', 'LICENSE-Lucide.txt'),
      ('Nunito', 'OFL-Nunito.txt'),
      ('Fredoka', 'OFL-Fredoka.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([
        name,
      ], await rootBundle.loadString('assets/fonts/$file'));
    }
  });
  // The apps have the code of every area; only the web app fetches the
  // rarely used ones when they are opened (see deferred_sections.dart).
  if (!kIsWeb) await loadAllSections();
  final state = AppState();
  await state.init();
  runApp(FamioApp(state: state));
}
