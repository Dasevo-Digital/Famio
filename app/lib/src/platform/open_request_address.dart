/// The query parameter with which a tapped browser notification opens the
/// web app at what it is about (`?open=task:…`, #385).
const openRequestParameter = 'open';

/// [address] without [openRequestParameter], as the browser should show
/// it once the web app has read it: else every reload would open the same
/// thing again (#579). Null if there is nothing to remove. Path, other
/// parameters and fragment stay; the result is relative to the origin.
String? addressWithoutOpenRequest(Uri address) {
  if (!address.queryParametersAll.containsKey(openRequestParameter)) {
    return null;
  }
  final rest = Map.of(address.queryParametersAll)..remove(openRequestParameter);
  return Uri(
    path: address.path.isEmpty ? '/' : address.path,
    queryParameters: rest.isEmpty ? null : rest,
    fragment: address.hasFragment ? address.fragment : null,
  ).toString();
}
