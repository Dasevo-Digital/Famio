import 'package:flutter/widgets.dart';

/// Disposes [controllers] together with this widget.
///
/// Wrap a dialog's content in it instead of disposing after `showDialog`
/// returns: the future completes when the dialog is popped, but the dialog
/// keeps building (with the controllers) during its closing animation.
class DisposeWith extends StatefulWidget {
  const DisposeWith({
    super.key,
    required this.controllers,
    required this.child,
  });

  final List<ChangeNotifier> controllers;
  final Widget child;

  @override
  State<DisposeWith> createState() => _DisposeWithState();
}

class _DisposeWithState extends State<DisposeWith> {
  @override
  void dispose() {
    for (final c in widget.controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
