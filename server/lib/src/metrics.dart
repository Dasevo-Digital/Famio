import 'dart:io';

import 'package:shelf/shelf.dart';

/// Counters for `/metrics`: how the server is doing, never what the family
/// stores (no names, no contents, no ids).
class ServerMetrics {
  final startedAt = DateTime.now();

  /// Responses by status class ("2xx" … "5xx").
  final responses = <String, int>{};
  var syncRequests = 0;
  var pushSent = 0;
  var pushFailed = 0;

  /// Counts every response; the outermost middleware.
  Middleware get middleware =>
      (inner) => (request) async {
        final response = await inner(request);
        final kind = '${response.statusCode ~/ 100}xx';
        responses[kind] = (responses[kind] ?? 0) + 1;
        return response;
      };

  void pushResult({required bool ok}) => ok ? pushSent++ : pushFailed++;
}

/// One value of a metric, with optional labels.
typedef Sample = ({Map<String, String> labels, num value});

/// Writes metrics in the Prometheus text format (version 0.0.4).
class MetricsWriter {
  final _out = StringBuffer();

  /// A metric with [help] text; [samples] without labels for a single value.
  void add(String name, String help, String type, List<Sample> samples) {
    _out
      ..writeln('# HELP $name $help')
      ..writeln('# TYPE $name $type');
    for (final s in samples) {
      final labels = s.labels.isEmpty
          ? ''
          : '{${[for (final e in s.labels.entries) '${e.key}="${_escape(e.value)}"'].join(',')}}';
      _out.writeln('$name$labels ${_number(s.value)}');
    }
  }

  void gauge(String name, String help, num value) =>
      add(name, help, 'gauge', [(labels: const {}, value: value)]);

  void counter(String name, String help, num value) =>
      add(name, help, 'counter', [(labels: const {}, value: value)]);

  static String _escape(String v) =>
      v.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n');

  static String _number(num v) =>
      v is int || v == v.roundToDouble() ? '${v.round()}' : '$v';

  @override
  String toString() => _out.toString();
}

/// Resident memory of this process in bytes.
int residentMemory() => ProcessInfo.currentRss;
