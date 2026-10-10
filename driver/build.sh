#!/bin/bash
# Asistan'ın kendi sanal ses sürücüsünü derler (Loopback'in yerine geçmesi için deneme).
# Kaynak: BlackHole v0.7.2 (GPL-3.0), sabit sürümden indirilip yalnızca derleme ayarlarıyla özelleştirilir.
# İki ayrı aygıt oluşturur; birine çalınan ses diğerinden mikrofon olarak gelir:
#   "Asistan Sanal Çıkış"    yalnızca çıkış (asistan buraya konuşur)
#   "Asistan Sanal Mikrofon" yalnızca giriş (WhatsApp/FaceTime bunu mikrofon seçer)
set -euo pipefail
cd "$(dirname "$0")"
REPO="https://github.com/ExistentialAudio/BlackHole.git"
COMMIT="561d934c77a1fa64987e01ccabe890fed30e181f"  # v0.7.2
NAME="AsistanSes"
BUNDLE_ID="com.mtahca.asistan.audiodriver"
FACTORY="aeb52f16-2305-414e-8f91-984035345e10"
VERSION="0.1.0"
OUT="build/$NAME.driver"

if [ "$(uname -m)" != "arm64" ]; then echo "Sürücü Apple Silicon için derlenir."; exit 1; fi
command -v clang >/dev/null || { echo "clang yok: xcode-select --install ile Komut Satırı Araçlarını kurun."; exit 1; }

SRC="build/BlackHole"
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$COMMIT" ]; then
  rm -rf "$SRC"; mkdir -p build
  git init -q "$SRC"
  git -C "$SRC" fetch -q --depth 1 "$REPO" "$COMMIT"
  git -C "$SRC" checkout -q FETCH_HEAD
fi

# Aygıt adları ve kimlikleri. Varsayılanlar BlackHole.c içinde #ifndef ile tanımlı; bunlar önce gelir.
cat > build/config.h <<'H'
#define kDriver_Name              "AsistanSes"
#define kPlugIn_BundleID          "com.mtahca.asistan.audiodriver"
#define kPlugIn_Icon              "AsistanSes.icns"
#define kManufacturer_Name        "Asistan"
#define kHas_Driver_Name_Format   false
#define kDevice_Name              "Asistan Sanal Mikrofon"
#define kDevice_IsHidden          false
#define kDevice_HasInput          true
#define kDevice_HasOutput         false
#define kDevice2_Name             "Asistan Sanal Çıkış"
#define kDevice2_IsHidden         false
#define kDevice2_HasInput         false
#define kDevice2_HasOutput        true
#define kNumber_Of_Channels       2
#define kSampleRates              48000, 44100, 24000, 16000
H

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
clang -bundle -O2 -arch arm64 -mmacosx-version-min=12.0 -fvisibility=default \
  -include build/config.h "$SRC/BlackHole/BlackHole.c" \
  -framework CoreAudio -framework CoreFoundation -framework Accelerate \
  -o "$OUT/Contents/MacOS/$NAME"
iconutil -c icns ../app/AppIcon.iconset -o "$OUT/Contents/Resources/$NAME.icns"
cp "$SRC/LICENSE" "$OUT/Contents/Resources/LICENSE-BlackHole.txt"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>English</string>
	<key>CFBundleExecutable</key><string>$NAME</string>
	<key>CFBundleIconFile</key><string>$NAME.icns</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFPlugInFactories</key>
	<dict><key>$FACTORY</key><string>BlackHole_Create</string></dict>
	<key>CFPlugInTypes</key>
	<dict><key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key><array><string>$FACTORY</string></array></dict>
</dict>
</plist>
PLIST

# Asistan.app ile aynı yerel kimlik (make_cert.sh), yoksa geçici imza.
IDENT=$(/usr/bin/security find-identity -p codesigning 2>/dev/null | /usr/bin/awk '/AsistanLocal/ {print $2; exit}')
codesign --force --sign "${IDENT:--}" "$OUT"
codesign --verify --strict "$OUT"
echo "Sürücü derlendi: $(pwd)/$OUT"
echo "Kurmak için: bash driver/install.sh"
