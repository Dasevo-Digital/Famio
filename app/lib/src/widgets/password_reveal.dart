import 'dart:async';

import 'package:flutter/material.dart';

import '../design/app_icons.dart';
import '../l10n.dart';

/// Lets a password field show its text for a few seconds, e.g. to check a
/// typo – then it hides again by itself.
///
///     PasswordReveal(
///       builder: (context, obscure, toggle) => TextField(
///         obscureText: obscure,
///         contextMenuBuilder: PasswordReveal.contextMenu,
///         decoration: InputDecoration(suffixIcon: toggle),
///       ),
///     )
class PasswordReveal extends StatefulWidget {
  const PasswordReveal({super.key, required this.builder});

  final Widget Function(BuildContext context, bool obscure, Widget toggle)
  builder;

  /// How long the password stays visible.
  static const visibleFor = Duration(seconds: 5);

  /// Context menu of password fields (right click, long press): always
  /// offers "Einfügen", e.g. from a password manager. Copying stays off.
  ///
  ///     TextField(obscureText: obscure,
  ///         contextMenuBuilder: PasswordReveal.contextMenu)
  static Widget contextMenu(BuildContext context, EditableTextState field) {
    final value = field.textEditingValue;
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: field.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          label: tr.passwordPaste,
          onPressed: () => field.pasteText(SelectionChangedCause.toolbar),
        ),
        if (value.text.isNotEmpty &&
            value.selection.end - value.selection.start < value.text.length)
          ContextMenuButtonItem(
            type: ContextMenuButtonType.selectAll,
            label: tr.passwordSelectAll,
            onPressed: () => field.selectAll(SelectionChangedCause.toolbar),
          ),
      ],
    );
  }

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
      tooltip: _visible ? tr.passwordHide : tr.passwordShowBriefly,
      onPressed: _toggle,
    );
    return widget.builder(context, !_visible, toggle);
  }
}
