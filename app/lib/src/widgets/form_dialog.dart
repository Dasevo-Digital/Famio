import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import '../l10n.dart';

/// Dialog that runs [onSubmit] and shows server errors inline.
class FormDialog extends StatefulWidget {
  const FormDialog({
    super.key,
    required this.title,
    required this.fields,
    required this.onSubmit,
    this.controllers = const [],
    this.submitLabel,
  });

  final String title;
  final List<Widget> fields;
  final Future<void> Function() onSubmit;
  final String? submitLabel;

  /// Disposed with the dialog, after its closing animation.
  final List<TextEditingController> controllers;

  @override
  State<FormDialog> createState() => _FormDialogState();
}

class _FormDialogState extends State<FormDialog> {
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in widget.controllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit();
      if (mounted) Navigator.pop(context);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Fits small phones with the keyboard open.
      scrollable: true,
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final field in widget.fields) ...[
              field,
              const SizedBox(height: 12),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(tr.commonCancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(widget.submitLabel ?? tr.commonSave),
        ),
      ],
    );
  }
}
