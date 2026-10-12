/// Negative if [a] is older than [b] (1.0.9 < 1.0.10; build numbers and
/// a leading "v" are ignored).
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p
        in v.trim().replaceFirst(RegExp('^v'), '').split('+').first.split('.'))
      int.tryParse(p) ?? 0,
  ];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}
