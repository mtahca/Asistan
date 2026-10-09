#!/bin/bash
# Başka bir Mac'e taşımak için dağıtım paketi: bash paketle.sh  ->  "Asistan <sürüm> Kurulum.zip"
# ZIP yalnızca uygulamayı içerir; API anahtarları, notlar, Python ortamı ve modeller dahil değildir.
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" app/Info.plist)
ZIP="Asistan $VERSION Kurulum.zip"
rm -f "$ZIP"
# ditto, uygulama paketinin izinlerini ve imzasını korur.
ditto -c -k --keepParent Asistan.app "$ZIP"
echo "Hazır: $(pwd)/$ZIP"
echo "Diğer Mac'te: ZIP'i açın, Asistan.app'i Uygulamalar'a taşıyın; açılmazsa DIGER_MAC_KURULUM.md içindeki karantina adımına bakın."
