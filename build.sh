#!/bin/bash
# Asistan.app'i derler:  ./build.sh   (ya da: bash build.sh)
set -e
cd "$(dirname "$0")"
APP="Asistan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/Asistan" app/main.swift
cp app/Info.plist "$APP/Contents/Info.plist"
# Kaynaklar: ajan, kurulum betiği, bağımlılık listesi, ses dosyaları
RES="$APP/Contents/Resources"
mkdir -p "$RES/sesler"
cp agent.py realtime_mode.py live_mode.py requirements.txt setup.sh "$RES/"
for f in sesler/*.wav; do [ -f "$f" ] && cp "$f" "$RES/sesler/"; done
# Uygulama simgesi (iconset -> icns)
if [ -d app/AppIcon.iconset ] && command -v iconutil >/dev/null; then
  iconutil -c icns app/AppIcon.iconset -o "$RES/AppIcon.icns" && echo "Simge: AppIcon.icns"
fi
IDENT=$(security find-identity -p codesigning | grep "AsistanLocal" | head -1 | awk '{print $2}')
if [ -n "$IDENT" ]; then
  codesign --force --deep --sign "$IDENT" "$APP"
  echo "İmza: AsistanLocal ($IDENT) — sabit; izinler korunur"
else
  codesign --force --deep --sign - "$APP"
  echo "İmza: geçici (her derlemede izinler sıfırlanabilir; make_cert.sh çalıştırılabilir)"
fi
echo "Hazır: $(pwd)/$APP"
