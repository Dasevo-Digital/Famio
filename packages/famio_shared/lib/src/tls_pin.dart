/// The DER `SubjectPublicKeyInfo` of an X.509 certificate.
///
/// Apps pin the server's key rather than its certificate: the server renews
/// its certificate (Apple devices accept at most 825 days) but keeps the key.
List<int> subjectPublicKeyInfo(List<int> certificateDer) {
  // Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version?,
  // serialNumber, signature, issuer, validity, subject, spki, … }, … }
  final cert = _Tlv.read(certificateDer, 0);
  final tbs = _Tlv.read(certificateDer, cert.contentStart);
  var offset = tbs.contentStart;
  var element = _Tlv.read(certificateDer, offset);
  if (element.tag == 0xA0) {
    offset = element.end;
    element = _Tlv.read(certificateDer, offset);
  }
  for (var i = 0; i < 5; i++) {
    offset = element.end;
    element = _Tlv.read(certificateDer, offset);
  }
  if (element.tag != 0x30) {
    throw const FormatException('Kein öffentlicher Schlüssel im Zertifikat');
  }
  return certificateDer.sublist(offset, element.end);
}

/// `AB:CD:…` in groups, like browsers show fingerprints.
String formatFingerprint(List<int> digest) => [
  for (final b in digest) b.toRadixString(16).padLeft(2, '0').toUpperCase(),
].join(':');

class _Tlv {
  const _Tlv(this.tag, this.contentStart, this.end);

  final int tag;
  final int contentStart;
  final int end;

  static _Tlv read(List<int> der, int offset) {
    if (offset + 2 > der.length) throw const FormatException('DER zu kurz');
    final tag = der[offset];
    var length = der[offset + 1];
    var start = offset + 2;
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      if (count == 0 || count > 4 || start + count > der.length) {
        throw const FormatException('Ungültige DER-Länge');
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | der[start + i];
      }
      start += count;
    }
    if (start + length > der.length) {
      throw const FormatException('DER zu kurz');
    }
    return _Tlv(tag, start, start + length);
  }
}
