#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build="$PWD/.local-build/mas"
mkdir -p "$build"
if [ ! -f "$build/source.tar.gz" ]; then
    curl --fail --location https://github.com/element-hq/matrix-authentication-service/archive/refs/tags/v1.26.0.tar.gz -o "$build/source.tar.gz"
fi
if [ ! -f "$build/assets.tar.gz" ]; then
    curl --fail --location https://github.com/element-hq/matrix-authentication-service/releases/download/v1.26.0/mas-cli-aarch64-linux.tar.gz -o "$build/assets.tar.gz"
fi
python3 - <<'PY'
from pathlib import Path
import hashlib
root = Path('.local-build/mas')
for name, expected in [('source.tar.gz','57dbb7dabf98182819da16af364797ba6bc58b2b97ac5cf246740352d2c4fa60'),
                       ('assets.tar.gz','0c4b7650133e5ea6ca031d5014f694563eebb577ee0efd9195708317bb87e7a7')]:
    if hashlib.sha256((root/name).read_bytes()).hexdigest() != expected:
        raise SystemExit('Archive checksum mismatch: ' + name)
PY
if [ ! -d "$build/matrix-authentication-service-1.26.0" ]; then
    tar -xzf "$build/source.tar.gz" -C "$build"
fi
if [ ! -d "$build/share" ]; then
    tar -xzf "$build/assets.tar.gz" -C "$build" share LICENSE
fi
python3 scripts/patch-mas-password-stdin.py "$build/matrix-authentication-service-1.26.0"
CARGO_BUILD_JOBS=2 CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
    cargo build --release --locked --manifest-path "$build/matrix-authentication-service-1.26.0/Cargo.toml" -p mas-cli
CARGO_BUILD_JOBS=2 cargo build --release --locked --manifest-path matrix/qr/Cargo.toml
