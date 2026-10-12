#!/bin/sh
# Signs SHA256SUMS.txt of a release with the Famio release key (Ed25519)
# and writes SHA256SUMS.txt.sig next to it: the raw 64-byte signature,
# base64. Server and apps install or offer an update only if this
# signature fits the public key in
# packages/famio_shared/lib/src/release_signature.dart.
#
#   sh tool/sign_release.sh <release folder with SHA256SUMS.txt>
#
# The private key lives only in the macOS keychain (service
# famio-release-signing-key) and goes through a pipe, never into a file.
set -eu
dir=${1:?release folder}
sums="$dir/SHA256SUMS.txt"
[ -f "$sums" ] || { echo "Fehlt: $sums" >&2; exit 1; }
openssl=/opt/homebrew/opt/openssl@3/bin/openssl
[ -x "$openssl" ] || openssl=openssl

key() { security find-generic-password -s famio-release-signing-key -a famio -w | base64 -d; }

key | "$openssl" pkeyutl -sign -rawin -inkey /dev/stdin -in "$sums" \
  | base64 | tr -d '\n' > "$sums.sig"
# Check it right away against the public half of the same key.
key | "$openssl" pkey -pubout > "$dir/.release-key.pub"
base64 -d < "$sums.sig" > "$dir/.release.sig"
"$openssl" pkeyutl -verify -rawin -pubin -inkey "$dir/.release-key.pub" \
  -in "$sums" -sigfile "$dir/.release.sig" >/dev/null
rm -f "$dir/.release-key.pub" "$dir/.release.sig"
echo "Signiert: $sums.sig"
