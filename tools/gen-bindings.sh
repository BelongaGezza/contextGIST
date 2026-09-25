#!/usr/bin/env bash
# Builds contextgist-ffi for the host arch and regenerates its Swift bindings.
#
# Unlike GIST's own gen-bindings.sh, this does not produce an .xcframework —
# contextGIST is macOS-only for now, so apps/macos/project.yml links directly
# against the staticlib this script builds (see LIBRARY_SEARCH_PATHS /
# OTHER_LDFLAGS there) rather than embedding a multi-platform framework.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GENERATED_DIR="$REPO_ROOT/apps/macos/Generated"

cd "$REPO_ROOT"

CARGO_OUT_DIR="debug"
if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    CARGO_OUT_DIR="release"
fi

echo "→ Building contextgist-ffi (${CARGO_OUT_DIR})..."
# macOS's default bash (3.2) throws "unbound variable" under `set -u` when
# expanding an empty array, so this branches instead of using a CONFIG_FLAG=() array.
if [ "$CARGO_OUT_DIR" = "release" ]; then
    cargo build -p contextgist-ffi --release
else
    cargo build -p contextgist-ffi
fi

LIB_PATH="$REPO_ROOT/target/$CARGO_OUT_DIR/libcontextgist_ffi.a"
if [ ! -f "$LIB_PATH" ]; then
    LIB_PATH="$REPO_ROOT/target/$CARGO_OUT_DIR/libcontextgist_ffi.dylib"
fi

echo "→ Generating Swift bindings from $LIB_PATH..."
mkdir -p "$GENERATED_DIR"

# uniffi 0.28+ no longer ships uniffi-bindgen on crates.io; contextgist-ffi
# builds its own via the "uniffi-bindgen-bin" feature (see
# crates/contextgist-ffi/uniffi-bindgen.rs). Install once with:
#   cargo install --path crates/contextgist-ffi --bin uniffi-bindgen \
#       --features uniffi-bindgen-bin --root ~/.cargo-uniffi-bindgen
# then add ~/.cargo-uniffi-bindgen/bin to PATH.
if command -v uniffi-bindgen &>/dev/null; then
    uniffi-bindgen generate --library "$LIB_PATH" --language swift --out-dir "$GENERATED_DIR"
elif cargo uniffi-bindgen --help &>/dev/null 2>&1; then
    cargo uniffi-bindgen generate --library "$LIB_PATH" --language swift --out-dir "$GENERATED_DIR"
else
    echo "uniffi-bindgen not found. See comment above this line for install steps."
    echo "Skipping binding generation — using existing generated files if present."
    exit 0
fi

echo "✓ Swift bindings written to $GENERATED_DIR/"
ls "$GENERATED_DIR/"
