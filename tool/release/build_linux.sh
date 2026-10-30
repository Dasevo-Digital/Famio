#!/bin/sh
# Builds the Linux package on a Linux machine with Flutter in ~/flutter:
#   sh build_linux.sh <version> [<flutter>]
# (famio-src.tgz from tool/release.sh in ~). Stops if Flutter is not
# <flutter>. Leaves ~/Famio-<version>-linux-x86_64.tar.gz.
set -eu
V="$1"
cd ~
if [ -n "${2:-}" ]; then
  case "$(~/flutter/bin/flutter --version 2>&1)" in
    "Flutter $2 "*) ;;
    *) echo "Flutter in ~/flutter ist nicht $2" >&2; exit 1 ;;
  esac
fi
rm -rf famio-build && mkdir famio-build && tar -xzf famio-src.tgz -C famio-build
cd famio-build
# The SQLite library of earlier builds instead of a download from github.com.
bash tool/hook_cache.sh restore
cd app
~/flutter/bin/flutter pub get >/dev/null
~/flutter/bin/flutter build linux --release 2>&1 | tail -2
(cd .. && bash tool/hook_cache.sh save)
pkg=~/Famio-$V-linux
rm -rf "$pkg" && mkdir -p "$pkg"
cp -r build/linux/x64/release/bundle "$pkg/bundle"
cp -r linux/packaging/icons linux/packaging/de.status403.famio.desktop linux/packaging/install.sh "$pkg/"
cd ~ && tar -czf "Famio-$V-linux-x86_64.tar.gz" "Famio-$V-linux" && rm -rf "$pkg"
ls -la ~/"Famio-$V-linux-x86_64.tar.gz"
