#!/bin/sh
set -eu

MODEL_KEY=qwen025
REPO="mlx-community/Qwen2.5-0.5B-Instruct-4bit"
REVISION="a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3"

[ "$(uname -s)" = Darwin ] || { echo "Local MLX inference requires macOS." >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "MLX polishing requires Apple Silicon (arm64)." >&2; exit 1; }

ROOT="$HOME/Library/Application Support/Typer/MLX"
MODEL_DIR="$ROOT/models/$MODEL_KEY"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKER_SOURCE=${1:-$SCRIPT_DIR/mlx_worker.py}
PYTHON=${PYTHON:-python3}
PY_MINOR=$($PYTHON -c 'import sys; print(sys.version_info.minor)')
PY_MAJOR=$($PYTHON -c 'import sys; print(sys.version_info.major)')
[ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -ge 10 ] && [ "$PY_MINOR" -lt 14 ] || {
  echo "Python 3.10 through 3.13 is supported; selected: $($PYTHON --version 2>&1)" >&2; exit 1;
}

mkdir -p "$ROOT" "$ROOT/models"
export HF_HUB_DISABLE_TELEMETRY=1
cp "$WORKER_SOURCE" "$ROOT/mlx_worker.py"
if [ ! -x "$ROOT/venv/bin/python3" ]; then "$PYTHON" -m venv "$ROOT/venv"; fi
"$ROOT/venv/bin/python3" -m pip install --upgrade 'pip==26.2.1'
"$ROOT/venv/bin/python3" -m pip install 'mlx-lm==0.31.3' 'mlx==0.32.3' 'transformers==5.17.0' 'huggingface_hub==1.5.0'
"$ROOT/venv/bin/python3" - "$REPO" "$REVISION" "$MODEL_DIR" <<'PY'
import sys
from huggingface_hub import snapshot_download
repo, revision, destination = sys.argv[1:]
snapshot_download(repo_id=repo, revision=revision, local_dir=destination)
print("Model files installed at:", destination)
PY
printf 'Local model ready: %s\n' "$REPO"
