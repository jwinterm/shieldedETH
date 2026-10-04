#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/toolchain
curl --fail --location --silent --show-error https://github.com/iden3/circom/archive/refs/tags/v2.1.9.tar.gz --output build/toolchain/circom-v2.1.9.tar.gz
printf '%s\n' 'ba2c82edabdca7190f4f152e3c4ebcdf3656805dc4c1c7e1d37a991d5a79e1cd  build/toolchain/circom-v2.1.9.tar.gz' | shasum -a 256 -c -
tar -xzf build/toolchain/circom-v2.1.9.tar.gz -C build/toolchain
cargo build --release --locked --manifest-path build/toolchain/circom-2.1.9/Cargo.toml
build/toolchain/circom-2.1.9/target/release/circom --version
