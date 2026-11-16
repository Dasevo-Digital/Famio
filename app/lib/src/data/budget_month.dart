import 'package:famio_client/famio_client.dart';

import '../l10n.dart';

/// Totals of one month.
class BudgetMonth {
  BudgetMonth(List<BudgetEntry> all, DateTime month)
    : entries = all.where((e) => e.inMonth(month)).toList() {
    for (final e in entries) {
      if (e.income) {
        income += e.cents;
      } else {
        expenses += e.cents;
        byCategory[e.category] = (byCategory[e.category] ?? 0) + e.cents;
      }
    }
  }

  final List<BudgetEntry> entries;
  var income = 0;
  var expenses = 0;
  final byCategory = <String, int>{};

  int get balance => income - expenses;
}

/// The categories to choose from for money in or out ([income]): the
/// default ones, then the family's own ones of that kind, e.g. from the
/// bank import ("Hund"), from other bookings in [entries] or with a limit
/// in [limits] (expenses only), sorted. [keep] (the booking's own
/// category) is always among them, so editing a booking keeps it.
List<String> budgetCategories({
  required bool income,
  Iterable<BudgetEntry> entries = const [],
  Iterable<String> limits = const [],
  String? keep,
}) {
  final defaults = income ? incomeCategories : expenseCategories;
  final own = <String>{
    for (final e in entries)
      if (e.income == income) e.category,
    if (!income) ...limits,
    ?keep,
  }..removeWhere((c) => c.trim().isEmpty || defaults.contains(c));
  return [
    ...defaults,
    ...own.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())),
  ];
}

/// The name of a budget category in the app's language. Entries keep the
/// German name of the default categories; own ones stay as they are.
String categoryLabel(String category) => switch (category) {
  'Lebensmittel' => tr.budgetGroceries,
  'Haushalt' => tr.budgetHousehold,
  'Wohnen' => tr.budgetHousing,
  'Mobilität' => tr.budgetMobility,
  'Kinder' => tr.budgetKids,
  'Gesundheit' => tr.budgetHealth,
  'Freizeit' => tr.budgetLeisure,
  'Kleidung' => tr.budgetClothing,
  'Versicherungen' => tr.budgetInsurance,
  'Sonstiges' => tr.budgetOther,
  'Gehalt' => tr.budgetSalary,
  'Kindergeld' => tr.budgetChildBenefit,
  'Elterngeld' => tr.budgetParentalAllowance,
  'Sonstige Einnahmen' => tr.budgetOtherIncome,
  _ => category,
};
