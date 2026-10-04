#!/bin/sh
set -eu
EXPERIMENT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$EXPERIMENT_ROOT"
PROVEKIT_REV=d2fe9cfcc78d8ddbe895042ad0c6310ef2dde7db
PROVEKIT_DIR=build/transparent/vendor/provekit
mkdir -p build/transparent/vendor
if [ ! -d "$PROVEKIT_DIR/.git" ]; then
    git clone --no-checkout https://github.com/worldfnd/ProveKit.git "$PROVEKIT_DIR"
    git -C "$PROVEKIT_DIR" checkout --detach "$PROVEKIT_REV"
fi
if [ "$(git -C "$PROVEKIT_DIR" rev-parse HEAD)" != "$PROVEKIT_REV" ]; then
    echo "Refusing: ProveKit checkout is not at the pinned experiment revision." >&2
    exit 1
fi
if [ -n "$(git -C "$PROVEKIT_DIR" status --porcelain)" ]; then
    echo "Refusing: ProveKit checkout contains local changes." >&2
    exit 1
fi
npm ci --ignore-scripts --prefix experiments/transparent
CARGO_HOME="$EXPERIMENT_ROOT/build/transparent/cargo-home" \
CARGO_TARGET_DIR="$EXPERIMENT_ROOT/build/transparent/target" \
    cargo +1.98.0 build --release --locked --manifest-path experiments/transparent/Cargo.toml
