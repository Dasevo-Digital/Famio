/// An error that is reported to the client as `{"error", "message"}` JSON.
class ApiException implements Exception {
  ApiException(this.status, this.code, this.message);

  ApiException.badRequest(this.code, this.message) : status = 400;

  final int status;
  final String code;
  final String message;

  @override
  String toString() => 'ApiException($status $code: $message)';
}
