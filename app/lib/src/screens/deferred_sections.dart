import 'package:famio_client/famio_client.dart';
import 'package:flutter/widgets.dart';

import '../widgets/deferred_page.dart';
import 'admin_screens.dart' deferred as admin;
import 'budget_screens.dart' deferred as budget;
import 'kids_screens.dart' deferred as kids;
import 'meals_screens.dart' deferred as meals;
import 'medication_screens.dart' deferred as health;

// Rarely opened areas: the web app fetches their code on first use, which
// makes its first start about a quarter lighter (the server administration
// alone brings the whole time zone database). One library for all deferred
// imports, so the apps can load every part at start.

/// Every part, loaded once: the apps call this at start (their code is
/// there already), as do the tests.
Future<void> loadAllSections() => Future.wait([
  DeferredPage.ensure('admin', admin.loadLibrary),
  DeferredPage.ensure('budget', budget.loadLibrary),
  DeferredPage.ensure('kids', kids.loadLibrary),
  DeferredPage.ensure('meals', meals.loadLibrary),
  DeferredPage.ensure('health', health.loadLibrary),
]);

Widget adminPage() => DeferredPage(
  id: 'admin',
  load: admin.loadLibrary,
  builder: (_) => admin.AdminScreen(),
);

Widget budgetPage() => DeferredPage(
  id: 'budget',
  load: budget.loadLibrary,
  builder: (_) => budget.BudgetScreen(),
);

Widget kidsPage() => DeferredPage(
  id: 'kids',
  load: kids.loadLibrary,
  builder: (_) => kids.KidsScreen(),
);

Widget mealsPage() => DeferredPage(
  id: 'meals',
  load: meals.loadLibrary,
  builder: (_) => meals.MealsScreen(),
);

Widget recipePage(String recipeId) => DeferredPage(
  id: 'meals',
  load: meals.loadLibrary,
  builder: (_) => meals.RecipeScreen(recipeId: recipeId),
);

Widget medicationPage() => DeferredPage(
  id: 'health',
  load: health.loadLibrary,
  builder: (_) => health.MedicationScreen(),
);

Future<void> openMedicationEditor(
  BuildContext context,
  Medication medication,
) async {
  await DeferredPage.ensure('health', health.loadLibrary);
  if (!context.mounted) return;
  await health.showMedicationEditor(context, medication: medication);
}
