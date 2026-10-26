import 'package:famio_client/famio_client.dart';

/// What the family lent to others or borrowed from them.
extension LoanData on SyncEngine {
  /// Open ones first, the soonest due first (without a date after those
  /// with one), then the returned ones, newest first.
  List<Loan> get loans =>
      records(Collections.loans).map(Loan.fromRecord).toList()..sort((a, b) {
        if (a.returned != b.returned) return a.returned ? 1 : -1;
        if (a.returned) {
          return (b.since ?? DateTime(0)).compareTo(a.since ?? DateTime(0));
        }
        return (a.due ?? DateTime(9999)).compareTo(b.due ?? DateTime(9999));
      });

  void saveLoan(Loan l) => put(Collections.loans, l.id, l.toData());

  void deleteLoan(String id) => delete(Collections.loans, id);

  /// Whose reminder a loan is: the member who lent or borrowed it, without
  /// one every adult.
  bool loanIsMine(Loan l, {required bool adult}) =>
      l.memberId == null ? adult : l.memberId == memberId;
}
