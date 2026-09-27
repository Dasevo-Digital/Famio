import 'dart:async';

import 'package:flutter/material.dart';

import '../design/app_icons.dart';

/// Lets a password field show its text for a few seconds, e.g. to check a
/// typo – then it hides again by itself.
///
///     PasswordReveal(
///       builder: (context, obscure, toggle) => TextField(
///         obscureText: obscure,
///         decoration: InputDecoration(suffixIcon: toggle),
///       ),
///     )
class PasswordReveal extends StatefulWidget {
  const PasswordReveal({super.key, required this.builder});

  final Widget Function(BuildContext context, bool obscure, Widget toggle)
  builder;

  /// How long the password stays visible.
  static const visibleFor = Duration(seconds: 5);

  @override
  State<PasswordReveal> createState() => _PasswordRevealState();
}

class _PasswordRevealState extends State<PasswordReveal> {
  var _visible = false;
  Timer? _hide;

  void _toggle() {
    _hide?.cancel();
    setState(() => _visible = !_visible);
    if (_visible) {
      _hide = Timer(PasswordReveal.visibleFor, () {
        if (mounted) setState(() => _visible = false);
      });
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final toggle = IconButton(
      icon: Icon(_visible ? AppIcons.eyeSlash : AppIcons.eye),
      tooltip: _visible ? 'Verbergen' : 'Kurz anzeigen',
      onPressed: _toggle,
    );
    return widget.builder(context, !_visible, toggle);
  }
}
