#!/bin/bash
set -euo pipefail
DATA="${1:?veri klasörü gerekli}"
RES="${2:?kaynak klasörü gerekli}"
MODE="${3:-local}"
if [ "$MODE" != "local" ] && [ "$MODE" != "gpt-live" ]; then exit 1; fi
mkdir -p "$DATA/bin"
chmod 700 "$DATA"
if [ "$MODE" = "gpt-live" ]; then rm -f "$DATA/.deps_ok_online"; else rm -f "$DATA/.deps_ok"; fi
step() { echo "STEP|$1|$2"; }
if [ "$(uname -m)" != "arm64" ]; then echo "Asistan Beta Apple Silicon gerektirir."; exit 1; fi
step uv start
if [ ! -x "$DATA/bin/uv" ]; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$DATA/bin" UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh
fi
step uv ok
step python start
if [ ! -x "$DATA/.venv/bin/python" ]; then "$DATA/bin/uv" venv --python 3.12 "$DATA/.venv"; fi
step python ok
step deps start
LOCK="$RES/requirements.lock"
if [ "$MODE" = "gpt-live" ]; then LOCK="$RES/requirements-online.lock"; fi
"$DATA/bin/uv" pip install --python "$DATA/.venv/bin/python" -r "$LOCK"
step deps ok
if [ "$MODE" = "gpt-live" ]; then
  "$DATA/.venv/bin/python" -B -c 'import numpy, sounddevice, httpx, anthropic, websocket'
  touch "$DATA/.deps_ok_online"
  step done ok
  exit 0
fi
step models start
# Verify BOTH local speech engines; a failed download must not appear as success.
ASISTAN_HOME="$DATA" ASISTAN_RES="$RES" "$DATA/.venv/bin/python" -B - <<'PY'
import os, sys, importlib.util
import numpy as np
from pathlib import Path
path = Path(os.environ['ASISTAN_RES']) / 'agent.py'
sys.path.insert(0, str(path.parent))
spec = importlib.util.spec_from_file_location('beta_setup', path)
beta = importlib.util.module_from_spec(spec); sys.modules[spec.name] = beta; spec.loader.exec_module(beta)
import mlx_whisper
mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo=beta.WHISPER_MODEL, language='tr', verbose=None)
from ema_lightning import EMA
speech = EMA(device='cpu').say('Merhaba.', sample_rate=48000)
assert len(speech.audio) > 0
print('Konuşma tanıma ve ses üretimi doğrulandı.')
PY
step models ok
touch "$DATA/.deps_ok"
step done ok
