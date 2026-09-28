/// Browser-only helpers; the installed apps never call them.
void downloadBytes(List<int> bytes, String name, String mime) =>
    throw UnsupportedError('Only in the web app');

/// The address the web app was loaded from.
Uri? get pageUrl => null;

/// Per-tab browser storage; the installed apps have none.
String? tabValue(String key) => null;

void setTabValue(String key, String? value) {}
