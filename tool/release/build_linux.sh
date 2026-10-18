#!/bin/sh
# Builds the Linux package on a Linux machine with Flutter in ~/flutter:
#   sh build_linux.sh <version>   (famio-src.tgz from tool/release.sh in ~)
# Leaves ~/Famio-<version>-linux-x86_64.tar.gz.
set -eu
V="$1"
cd ~
rm -rf famio-build && mkdir famio-build && tar -xzf famio-src.tgz -C famio-build
cd famio-build/app
~/flutter/bin/flutter pub get >/dev/null
~/flutter/bin/flutter build linux --release 2>&1 | tail -2
pkg=~/Famio-$V-linux
rm -rf "$pkg" && mkdir -p "$pkg"
cp -r build/linux/x64/release/bundle "$pkg/bundle"
cp -r linux/packaging/icons linux/packaging/de.status403.famio.desktop linux/packaging/install.sh "$pkg/"
cd ~ && tar -czf "Famio-$V-linux-x86_64.tar.gz" "Famio-$V-linux" && rm -rf "$pkg"
ls -la ~/"Famio-$V-linux-x86_64.tar.gz"
