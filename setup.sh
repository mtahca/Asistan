#!/bin/bash
set -euo pipefail
DATA="${1:?veri klasörü gerekli}"
RES="${2:?kaynak klasörü gerekli}"
MODE="${3:-local}"
# Both online voice modes (GPT-Live, Gemini Live) share the light online dependency set.
if [ "$MODE" = "gemini-live" ]; then MODE="gpt-live"; fi
if [ "$MODE" != "local" ] && [ "$MODE" != "gpt-live" ]; then exit 1; fi
mkdir -p "$DATA/bin"
chmod 700 "$DATA"
if [ "$MODE" = "gpt-live" ]; then rm -f "$DATA/.deps_ok_online"; else rm -f "$DATA/.deps_ok"; fi
step() { echo "STEP|$1|$2"; }
if [ "$(uname -m)" != "arm64" ]; then echo "Asistan Apple Silicon gerektirir."; exit 1; fi
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
# Versions the user updated from the setup screen survive a repair/reinstall.
if [ "$MODE" = "local" ] && [ -f "$DATA/local_overrides.txt" ]; then
  "$DATA/bin/uv" pip install --python "$DATA/.venv/bin/python" -r "$DATA/local_overrides.txt"
fi
step deps ok
if [ "$MODE" = "gpt-live" ]; then
  "$DATA/.venv/bin/python" -B -c 'import numpy, sounddevice, httpx, anthropic, websocket'
  touch "$DATA/.deps_ok_online"
  step done ok
  exit 0
fi
step models start
# Verify BOTH local speech engines; a failed download must not appear as success.
ASISTAN_HOME="$DATA" ASISTAN_RES="$RES" "$DATA/.venv/bin/python" -B "$RES/local_models.py" verify
step models ok
touch "$DATA/.deps_ok"
step done ok
