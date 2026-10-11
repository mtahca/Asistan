#!/bin/bash
# Başka bir Mac'e taşımak için dağıtım paketi: bash paketle.sh  ->  "Asistan <sürüm> Kurulum.zip"
# ZIP yalnızca uygulamayı içerir; API anahtarları, notlar, Python ortamı ve modeller dahil değildir.
#
# Keychain'de "Developer ID Application" sertifikası varsa uygulama onunla imzalanır (hardened runtime).
# Ek olarak bir notarytool profili verilirse Apple'a notarize ettirilir ve diğer Mac'te uyarı çıkmaz:
#   xcrun notarytool store-credentials asistan-notary        (bir kez, parolayı siz yazarsınız)
#   ASISTAN_NOTARY_PROFILE=asistan-notary bash paketle.sh
# Sertifika yoksa eskisi gibi yerel imzalı, notarize edilmemiş bir ZIP üretilir.
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${ASISTAN_SIGN_IDENTITY:-}" ]; then
  ASISTAN_SIGN_IDENTITY=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk '/Developer ID Application/ {print $2; exit}' || true)
fi
export ASISTAN_SIGN_IDENTITY
if [ -n "${ASISTAN_NOTARY_PROFILE:-}" ] && { [ -z "$ASISTAN_SIGN_IDENTITY" ] || [ "$ASISTAN_SIGN_IDENTITY" = "-" ]; }; then
  echo "ASISTAN_NOTARY_PROFILE verildi ama Developer ID Application sertifikası bulunamadı."; exit 1
fi
bash build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" app/Info.plist)
ZIP="Asistan $VERSION Kurulum.zip"
rm -f "$ZIP"
if [ -n "${ASISTAN_NOTARY_PROFILE:-}" ]; then
  SUBMIT="${TMPDIR:-/tmp}/asistan-notarize.zip"
  rm -f "$SUBMIT"
  ditto -c -k --keepParent Asistan.app "$SUBMIT"
  xcrun notarytool submit "$SUBMIT" --keychain-profile "$ASISTAN_NOTARY_PROFILE" --wait
  rm -f "$SUBMIT"
  xcrun stapler staple Asistan.app
  xcrun stapler validate Asistan.app
  spctl --assess --type execute -vv Asistan.app
  NOTE="Developer ID ile imzalı ve Apple tarafından notarize edilmiş: diğer Mac'te uyarı çıkmaz."
elif [ -n "$ASISTAN_SIGN_IDENTITY" ]; then
  NOTE="Developer ID ile imzalı ama notarize edilmemiş: ilk açılışta macOS uyarı verebilir (ASISTAN_NOTARY_PROFILE ile notarize edin)."
else
  NOTE="Yerel imzalı, notarize edilmemiş: diğer Mac'te DIGER_MAC_KURULUM.md içindeki karantina adımı gerekir."
fi
# ditto, uygulama paketinin izinlerini ve imzasını korur.
ditto -c -k --keepParent Asistan.app "$ZIP"
echo "Hazır: $(pwd)/$ZIP"
echo "$NOTE"
echo "Diğer Mac'te: ZIP'i açın, Asistan.app'i Uygulamalar'a taşıyın (adımlar DIGER_MAC_KURULUM.md içinde)."
