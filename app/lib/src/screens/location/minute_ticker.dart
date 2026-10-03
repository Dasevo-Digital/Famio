part of '../location_screens.dart';

/// Keeps a widget rebuilding every minute ("vor 3 Min.").
class MinuteTicker extends StatefulWidget {
  const MinuteTicker({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  State<MinuteTicker> createState() => _MinuteTickerState();
}

class _MinuteTickerState extends State<MinuteTicker> {
  late final Timer _timer = Timer.periodic(
    const Duration(minutes: 1),
    (_) => setState(() {}),
  );

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _timer; // Starts the timer.
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
