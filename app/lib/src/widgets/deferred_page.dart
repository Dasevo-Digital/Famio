import 'package:flutter/material.dart';

import '../l10n.dart';

/// A page whose code the web app fetches only when it is first opened
/// (a deferred import, see screens/deferred_sections.dart): the first start
/// loads less. The apps load every part at start, so their pages show right
/// away.
class DeferredPage extends StatefulWidget {
  const DeferredPage({
    super.key,
    required this.id,
    required this.load,
    required this.builder,
  });

  /// Names the part, so a loaded one is not waited for again.
  final String id;

  /// The deferred library's `loadLibrary`.
  final Future<void> Function() load;
  final WidgetBuilder builder;

  static final _loaded = <String>{};

  /// Loads part [id] once.
  static Future<void> ensure(String id, Future<void> Function() load) async {
    if (_loaded.contains(id)) return;
    await load();
    _loaded.add(id);
  }

  @override
  State<DeferredPage> createState() => _DeferredPageState();
}

class _DeferredPageState extends State<DeferredPage> {
  late Future<void>? _loading = DeferredPage._loaded.contains(widget.id)
      ? null
      : DeferredPage.ensure(widget.id, widget.load);

  @override
  Widget build(BuildContext context) {
    final loading = _loading;
    if (loading == null) return widget.builder(context);
    return FutureBuilder<void>(
      future: loading,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          // Offline in the browser: the part could not be fetched.
          return Center(
            child: TextButton(
              onPressed: () => setState(
                () => _loading = DeferredPage.ensure(widget.id, widget.load),
              ),
              child: Text(tr.deferredRetry),
            ),
          );
        }
        return widget.builder(context);
      },
    );
  }
}
