#!/bin/bash
# Derlenen sürücüyü kurar ve Core Audio'yu yeniden başlatır (yönetici parolası ister; açık görüşmelerin sesi bir an kesilir).
set -euo pipefail
cd "$(dirname "$0")"
SRC="build/AsistanSes.driver"
DEST="/Library/Audio/Plug-Ins/HAL/AsistanSes.driver"
[ -d "$SRC" ] || { echo "Önce derleyin: bash driver/build.sh"; exit 1; }
sudo rm -rf "$DEST"
sudo cp -R "$SRC" "$DEST"
sudo chown -R root:wheel "$DEST"
sudo killall coreaudiod
sleep 3
echo "Kuruldu. Görünen Asistan aygıtları:"
system_profiler SPAudioDataType 2>/dev/null | grep -E "^ {8}Asistan Sanal" || echo "  (henüz görünmüyor; birkaç saniye sonra Audio MIDI Setup'ta bakın)"
