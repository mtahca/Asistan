#!/bin/bash
# Dağıtım imzası: Asistan.app'i Developer ID (ya da "-" ile geçici imza) ve hardened runtime ile imzalar.
# Apple'ın notarize işlemi için iç içe her çalıştırılabilir dosya bu şekilde imzalanmış olmalıdır.
# Kullanım: bash sign_app.sh <Asistan.app> <kimlik adı, SHA-1 veya "-">
set -euo pipefail
cd "$(dirname "$0")"
APP="${1:?Asistan.app yolu gerekli}"
IDENT="${2:?imza kimliği gerekli}"
ENT="app/Asistan.entitlements"
TS=(--timestamp)
[ "$IDENT" = "-" ] && TS=(--timestamp=none)  # geçici imzada zaman damgası sunucusu kullanılmaz
sign() { codesign --force --options runtime "${TS[@]}" "$@"; }
# En içten dışa: sürücü, konuşma yardımcısı, uygulama.
sign --sign "$IDENT" "$APP/Contents/Resources/AsistanSes.driver"
sign --entitlements "$ENT" --sign "$IDENT" "$APP/Contents/MacOS/asistan-speech"
sign --entitlements "$ENT" --sign "$IDENT" "$APP"
codesign --verify --strict --deep "$APP"
echo "İmzalandı ($([ "$IDENT" = "-" ] && echo geçici || echo "Developer ID"), hardened runtime): $APP"
