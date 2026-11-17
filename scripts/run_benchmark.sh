#!/bin/sh
# Runs the dictation benchmark matrix and prints one RESULT line per run.
# Usage: scripts/run_benchmark.sh [benchmark-binary] > results.txt
set -eu
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$(cd "$REPO_ROOT" && swift build -c release --show-bin-path)/VoiceTypingBenchmark"}
AUDIO=${AUDIO:-"$REPO_ROOT/.build/benchmark-audio"}
VOICES=${VOICES:-"Samantha Daniel Aman Karen Moira"}
ENGINE=${ENGINE:-speech}
for voice in $VOICES; do
  for mode in polished verbatim; do
    "$BIN" --audio-dir="$AUDIO/$voice/dictation" --sentences="$REPO_ROOT/Benchmarks/dictation.txt" \
      --engine=$ENGINE --mode=$mode --label="$voice/dictation" | grep '^RESULT' || echo "RESULT label=$voice/dictation mode=$mode FAILED"
  done
  for words in none custom; do
    # Pass the word list as a real argument; paths may contain spaces.
    if [ "$words" = custom ]; then set -- "--words=$REPO_ROOT/Benchmarks/jargon-words.txt"; else set --; fi
    "$BIN" --audio-dir="$AUDIO/$voice/jargon" --sentences="$REPO_ROOT/Benchmarks/jargon.txt" \
      --engine=$ENGINE --mode=polished --label="$voice/jargon-$words" "$@" | grep '^RESULT' || echo "RESULT label=$voice/jargon-$words FAILED"
  done
done
