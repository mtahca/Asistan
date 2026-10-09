#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD_CACHE="${ASISTAN_BUILD_CACHE:-${TMPDIR:-/tmp}/asistan-beta-swift-cache}"
mkdir -p "$BUILD_CACHE"
export CLANG_MODULE_CACHE_PATH="$BUILD_CACHE"
export SWIFT_MODULECACHE_PATH="$BUILD_CACHE"
BETA="${ASISTAN_BETA_BUILD_OUTPUT:-Asistan Beta.app}"
mkdir -p "$BETA/Contents/MacOS" "$BETA/Contents/Resources"
swiftc -O -module-cache-path "$BUILD_CACHE" -o "$BETA/Contents/MacOS/AsistanBeta" app/main.swift app/Protocol.swift app/ModelConfiguration.swift app/ModelSettings.swift app/CallPolicy.swift app/CallerIdentity.swift app/AssistantPreferences.swift app/Personalization.swift app/Setup.swift app/MobileProtocol.swift app/MobileBridge.swift app/MobileSettings.swift app/FocusMonitor.swift
cp app/Info.plist "$BETA/Contents/Info.plist"
cp app/Beta.icns "$BETA/Contents/Resources/"
cp agent.py llm.py live.py setup.sh requirements.txt requirements.lock requirements-online.lock "$BETA/Contents/Resources/"
rm -rf "$BETA/Contents/Resources/vendor"
cp -R vendor "$BETA/Contents/Resources/vendor"
# Use the existing stable local signing identity, without changing certificates or permissions.
IDENT=$(/usr/bin/security find-identity -p codesigning 2>/dev/null | /usr/bin/awk '/AsistanLocal/ {print $2; exit}')
if [ -z "$IDENT" ]; then IDENT="-"; fi
codesign --force --sign "$IDENT" "$BETA"
codesign --verify --strict "$BETA"
echo "Asistan Beta derlendi."
