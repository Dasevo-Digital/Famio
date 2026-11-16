import 'package:flutter/material.dart';

import '../app_state.dart';
import '../design/palette.dart';
import '../l10n.dart';

/// Signs out, asking first when the last sync failed and changes made on
/// this device would be lost (#337). [more] may ask something else before
/// (it runs after that question); false stays signed in.
Future<bool> signOutAsking(
  BuildContext context, {
  Future<bool> Function()? more,
}) => AppScope.read(context).signOut(
  proceed: (unsent) async {
    if (unsent > 0 && !await confirmUnsentSignOut(context, unsent)) {
      return false;
    }
    if (more == null) return true;
    return context.mounted && await more();
  },
);

/// "N Änderungen sind noch nicht übertragen …": true signs out anyway.
Future<bool> confirmUnsentSignOut(BuildContext context, int unsent) async {
  if (!context.mounted) return false;
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr.signOutUnsentTitle),
      content: Text(tr.signOutUnsentBody(unsent)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            tr.signOutAnyway,
            style: TextStyle(color: FamioColors.of(context).danger),
          ),
        ),
      ],
    ),
  );
  return answer ?? false;
}
