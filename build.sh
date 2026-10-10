#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD_CACHE="${ASISTAN_BUILD_CACHE:-${TMPDIR:-/tmp}/asistan-swift-cache}"
mkdir -p "$BUILD_CACHE"
export CLANG_MODULE_CACHE_PATH="$BUILD_CACHE"
export SWIFT_MODULECACHE_PATH="$BUILD_CACHE"
APP="${ASISTAN_BUILD_OUTPUT:-Asistan.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -module-cache-path "$BUILD_CACHE" -o "$APP/Contents/MacOS/Asistan" app/*.swift
cp app/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns app/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp agent.py llm.py live.py setup.sh requirements.txt requirements.lock requirements-online.lock "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/vendor"
cp -R vendor "$APP/Contents/Resources/vendor"
# Use the stable local signing identity (make_cert.sh) when present, so permissions survive rebuilds.
IDENT=$(/usr/bin/security find-identity -p codesigning 2>/dev/null | /usr/bin/awk '/AsistanLocal/ {print $2; exit}')
if [ -z "$IDENT" ]; then IDENT="-"; echo "Uyarı: AsistanLocal kimliği yok; geçici imza kullanılıyor (bash make_cert.sh ile oluşturabilirsiniz)."; fi
codesign --force --sign "$IDENT" "$APP"
codesign --verify --strict "$APP"
echo "Asistan derlendi: $(pwd)/$APP"
