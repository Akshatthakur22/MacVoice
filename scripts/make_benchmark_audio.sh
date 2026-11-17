#!/bin/sh
# Renders each benchmark sentence with macOS system voices (offline, built in)
# into 16 kHz mono WAV files: <out>/<voice>/<corpus>/NN.wav
set -eu
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-"$REPO_ROOT/.build/benchmark-audio"}
VOICES=${VOICES:-"Samantha Daniel Aman Karen Moira"}
for voice in $VOICES; do
  for corpus in dictation jargon; do
    dir="$OUT/$voice/$corpus"
    mkdir -p "$dir"
    n=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      n=$((n + 1))
      say -v "$voice" --file-format=WAVE --data-format=LEI16@16000 -o "$dir/$(printf %02d $n).wav" "$line"
    done < "$REPO_ROOT/Benchmarks/$corpus.txt"
  done
done
echo "$OUT"
