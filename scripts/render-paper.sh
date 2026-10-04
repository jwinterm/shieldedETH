#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
node scripts/update-evidence.js --check
node experiments/transparent/run.cjs --check
QUARTO_BIN="${SETH_QUARTO:-$PWD/build/toolchain/bin/quarto}"
export PATH="$PWD/build/toolchain/tectonic:$PATH"
# Render locally. No publishing or deployment is part of this script.
"$QUARTO_BIN" render docs/shieldedeth.qmd --to pdf
