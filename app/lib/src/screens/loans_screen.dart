import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/family_data.dart';
import '../data/loans.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import '../widgets/undo_delete.dart';
import '../l10n.dart';

DateFormat get _date => DateFormat.yMd(appLanguage);

/// The drill at the neighbours', the book from Mia's friend: what the
/// family lent out or borrowed, with a reminder when it should be back.
class LoansScreen extends StatelessWidget {
  const LoansScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      collections: const {Collections.loans, 'members'},
      builder: (context, engine) {
        final all = engine.loans;
        final lent = [
          for (final l in all)
            if (!l.returned && l.lentOut) l,
        ];
        final borrowed = [
          for (final l in all)
            if (!l.returned && !l.lentOut) l,
        ];
        final returned = [
          for (final l in all)
            if (l.returned) l,
        ].take(20).toList();
        final c = FamioColors.of(context);
        final accent = c.strong(FamioSection.home);
        return SectionPage(
          section: FamioSection.home,
          title: tr.loansTitle,
          subtitle: tr.loansSubtitle,
          maxBodyWidth: 720,
          floating: AddButton(
            color: accent,
            tooltip: tr.loansAdd,
            onPressed: () => showLoanEditor(context, engine),
          ),
          body: ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              if (lent.isEmpty && borrowed.isEmpty)
                SoftCard(child: Text(tr.loansEmpty)),
              if (lent.isNotEmpty) ...[
                ListHeading(tr.loansLentOut, color: accent),
                for (final l in lent) _LoanCard(loan: l, engine: engine),
              ],
              if (borrowed.isNotEmpty) ...[
                ListHeading(tr.loansBorrowed, color: accent),
                for (final l in borrowed) _LoanCard(loan: l, engine: engine),
              ],
              if (returned.isNotEmpty) ...[
                ListHeading(tr.loansReturnedHeading, color: accent),
                for (final l in returned) _LoanCard(loan: l, engine: engine),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _LoanCard extends StatelessWidget {
  const _LoanCard({required this.loan, required this.engine});

  final Loan loan;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final l = loan;
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final overdue = l.overdueOn(DateTime.now());
    final who = l.memberId == null ? null : engine.member(l.memberId!);
    final details = [
      if (l.person.isNotEmpty)
        l.lentOut ? tr.loansLentTo(l.person) : tr.loansBorrowedFrom(l.person),
      if (l.since != null) tr.loansSince(_date.format(l.since!)),
      if (l.note.isNotEmpty) l.note,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SoftCard(
        color: l.returned ? c.surfaceSoft : null,
        onTap: () => showLoanEditor(context, engine, existing: l),
        child: Row(
          children: [
            if (who != null) ...[
              MemberAvatar(who, radius: 16),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      decoration: l.returned
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  if (details.isNotEmpty) Text(details),
                  if (!l.returned && l.due != null)
                    Text(
                      overdue
                          ? tr.loansOverdueSince(_date.format(l.due!))
                          : tr.loansDueOn(_date.format(l.due!)),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: overdue ? theme.colorScheme.error : c.inkSoft,
                        fontWeight: overdue ? FontWeight.w700 : null,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: l.returned ? tr.loansNotReturned : tr.loansMarkReturned,
              icon: Icon(l.returned ? AppIcons.rotateCcw : AppIcons.check),
              onPressed: () =>
                  engine.saveLoan(l.copyWith(returned: !l.returned)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Adds a loan or edits [existing].
Future<void> showLoanEditor(
  BuildContext context,
  SyncEngine engine, {
  Loan? existing,
}) async {
  final title = TextEditingController(text: existing?.title);
  final person = TextEditingController(text: existing?.person);
  final note = TextEditingController(text: existing?.note);
  var lentOut = existing?.lentOut ?? true;
  String? memberId = existing == null ? engine.memberId : existing.memberId;
  var due = existing?.due;
  final people = [
    for (final m in engine.members)
      if (!m.isGuest) m,
  ];
  final save = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        scrollable: true,
        title: Text(existing == null ? tr.loansNew : tr.loansEdit),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: true, label: Text(tr.loansLentOut)),
                ButtonSegment(value: false, label: Text(tr.loansBorrowed)),
              ],
              selected: {lentOut},
              onSelectionChanged: (v) => setState(() => lentOut = v.first),
            ),
            TextField(
              controller: title,
              autofocus: existing == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr.loansWhat),
            ),
            TextField(
              controller: person,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: lentOut ? tr.loansToWhom : tr.loansFromWhom,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              initialValue: people.any((m) => m.id == memberId)
                  ? memberId
                  : null,
              decoration: InputDecoration(labelText: tr.loansWhoOfUs),
              items: [
                DropdownMenuItem(value: null, child: Text(tr.loansAllAdults)),
                for (final m in people)
                  DropdownMenuItem(value: m.id, child: Text(m.displayName)),
              ],
              onChanged: (v) => setState(() => memberId = v),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.calendarBlank),
              title: Text(tr.loansDueBack),
              subtitle: Text(due == null ? tr.loansNoDate : _date.format(due!)),
              trailing: due == null
                  ? null
                  : IconButton(
                      tooltip: tr.loansNoDate,
                      icon: const Icon(AppIcons.x),
                      onPressed: () => setState(() => due = null),
                    ),
              onTap: () async {
                final now = DateTime.now();
                final picked = await showFamioDatePicker(
                  context: dialogContext,
                  initialDate:
                      due ?? DateTime(now.year, now.month, now.day + 14),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => due = picked);
              },
            ),
            TextField(
              controller: note,
              decoration: InputDecoration(labelText: tr.commonNote),
            ),
          ],
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
                deleteWithUndo(
                  context,
                  what: existing.title,
                  collections: const {Collections.loans},
                  delete: () => engine.deleteLoan(existing.id),
                );
              },
              child: Text(tr.commonDelete),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr.commonSave),
          ),
        ],
      ),
    ),
  );
  if (save == true && title.text.trim().isNotEmpty) {
    final now = DateTime.now();
    engine.saveLoan(
      Loan(
        id: existing?.id ?? newId(),
        title: title.text.trim(),
        lentOut: lentOut,
        person: person.text.trim(),
        memberId: memberId,
        since: existing?.since ?? DateTime(now.year, now.month, now.day),
        due: due,
        returned: existing?.returned ?? false,
        note: note.text.trim(),
      ),
    );
  }
  // Not disposed: the dialog still shows them while it closes.
}
