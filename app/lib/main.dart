import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'src/app.dart';
import 'src/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de');
  // Famio speaks German, whatever the device or browser is set to (an
  // English browser would otherwise format with missing locale data).
  Intl.defaultLocale = 'de';
  final state = AppState();
  await state.init();
  runApp(FamioApp(state: state));
}
