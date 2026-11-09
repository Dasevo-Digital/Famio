import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../l10n.dart';
import 'dispose_with.dart';
import 'password_reveal.dart';

/// The member's password, before something that keeps access to the account
/// (a calendar password, a push address …). Null when cancelled; empty for an
/// account without a password, which has nothing to confirm.
Future<String?> askAccountPassword(BuildContext context) async {
  final api = AppScope.read(context).engine!.api;
  try {
    if (!await api.hasPassword()) return '';
  } on ApiError {
    // Offline or the like: the request itself will tell.
  }
  if (!context.mounted) return null;
  final field = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => DisposeWith(
      controllers: [field],
      child: AlertDialog(
        title: Text(tr.accountPasswordTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.accountPasswordHint),
            const SizedBox(height: 12),
            PasswordReveal(
              builder: (_, obscure, toggle) => TextField(
                controller: field,
                autofocus: true,
                obscureText: obscure,
                contextMenuBuilder: PasswordReveal.contextMenu,
                decoration: InputDecoration(
                  labelText: tr.commonPassword,
                  suffixIcon: toggle,
                ),
                onSubmitted: (_) => Navigator.pop(context, field.text),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: Text(tr.commonConfirm),
          ),
        ],
      ),
    ),
  );
}
