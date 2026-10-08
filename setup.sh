#!/bin/bash
# Asistan kurulum betiği (uygulama içinden ya da elle çalıştırılır).
# Kullanım: setup.sh <VERI_KLASORU> <KAYNAK_KLASORU>
#   VERI_KLASORU   : ~/Library/Application Support/Asistan  (python ortamı, .env, notlar burada)
#   KAYNAK_KLASORU : requirements.txt'nin bulunduğu klasör
# Her adım yeniden çalıştırılabilir (zaten kuruluysa atlanır).
set -u
DATA="${1:?veri klasörü gerekli}"
RES="${2:?kaynak klasörü gerekli}"
mkdir -p "$DATA/bin"
say()  { echo "[$(date +%H:%M:%S)] $*"; }
step() { echo "STEP|$1|$2"; }

if [ "$(uname -m)" != "arm64" ]; then
  say "Bu uygulama Apple Silicon (M1/M2/M3/M4) gerektirir."
  step arch fail
  exit 1
fi

# 1) uv: Python'u ve paketleri hızlıca kurar (Homebrew gerekmez)
step uv start
if [ ! -x "$DATA/bin/uv" ]; then
  say "uv indiriliyor…"
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$DATA/bin" UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh \
    || { say "uv indirilemedi (internet bağlantısını kontrol et)."; step uv fail; exit 1; }
fi
step uv ok

# 2) Python 3.12 sanal ortamı
step python start
if [ ! -x "$DATA/.venv/bin/python" ]; then
  say "Python 3.12 kuruluyor…"
  "$DATA/bin/uv" venv --python 3.12 "$DATA/.venv" || { step python fail; exit 1; }
fi
step python ok

# 3) Paketler (konuşma tanıma, ses sentezi, Claude kütüphanesi…)
step deps start
say "Paketler kuruluyor (birkaç dakika sürebilir)…"
"$DATA/bin/uv" pip install --python "$DATA/.venv/bin/python" -r "$RES/requirements.txt" \
  || { say "Paket kurulumu başarısız."; step deps fail; exit 1; }
step deps ok

# 4) Modelleri önceden indir (ilk aramada bekleme olmasın)
step models start
say "Konuşma tanıma modeli indiriliyor (≈1.6 GB, yalnızca bir kez)…"
"$DATA/.venv/bin/python" - <<'PY' || say "Model indirmesi atlandı; ilk açılışta indirilecek."
import os
from huggingface_hub import snapshot_download
snapshot_download(os.getenv("WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo"))
PY
step models ok

touch "$DATA/.deps_ok"
say "Kurulum tamamlandı."
step done ok
