import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'src/app.dart';
import 'src/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Dates in every language the app speaks (AppState.init picks one).
  await initializeDateFormatting();
  final state = AppState();
  await state.init();
  runApp(FamioApp(state: state));
}
