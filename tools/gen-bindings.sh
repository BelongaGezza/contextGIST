#!/usr/bin/env bash
# Builds contextgist-ffi and regenerates its Swift bindings.
#
# Unlike GIST's own gen-bindings.sh, this does not produce an .xcframework —
# contextGIST is macOS-only for now, so apps/macos/project.yml links directly
# against the staticlib this script builds (see LIBRARY_SEARCH_PATHS /
# OTHER_LDFLAGS there) rather than embedding a multi-platform framework.
#
# Debug (the default when run by hand): host arch only, into
#   target/debug/libcontextgist_ffi.a
# Release (CONFIGURATION=Release, as Xcode sets it): a universal arm64 +
#   x86_64 staticlib, lipo'd into
#   target/universal/release/libcontextgist_ffi.a
# so the Release app runs on both Apple silicon and Intel Macs. project.yml
# points each configuration's LIBRARY_SEARCH_PATHS at exactly one of these,
# so a Debug build can never link a Release library or vice versa.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GENERATED_DIR="$REPO_ROOT/apps/macos/Generated"

cd "$REPO_ROOT"

if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
    UNIVERSAL_DIR="$REPO_ROOT/target/universal/release"
    SLICES=()
    for triple in "${TARGETS[@]}"; do
        echo "→ Building contextgist-ffi (release, $triple)..."
        cargo build -p contextgist-ffi --release --target "$triple"
        SLICES+=("$REPO_ROOT/target/$triple/release/libcontextgist_ffi.a")
    done
    mkdir -p "$UNIVERSAL_DIR"
    LIB_PATH="$UNIVERSAL_DIR/libcontextgist_ffi.a"
    echo "→ Combining slices into $LIB_PATH..."
    lipo -create "${SLICES[@]}" -output "$LIB_PATH"
    lipo -info "$LIB_PATH"
    # uniffi-bindgen reads metadata from a single-arch library; both slices
    # carry identical metadata, so use the first.
    BINDGEN_LIB="${SLICES[0]}"
else
    echo "→ Building contextgist-ffi (debug, host arch)..."
    cargo build -p contextgist-ffi
    LIB_PATH="$REPO_ROOT/target/debug/libcontextgist_ffi.a"
    BINDGEN_LIB="$LIB_PATH"
fi

if [ ! -f "$LIB_PATH" ]; then
    echo "error: expected $LIB_PATH after cargo build" >&2
    exit 1
fi

echo "→ Generating Swift bindings from $BINDGEN_LIB..."
mkdir -p "$GENERATED_DIR"

# uniffi 0.28+ no longer ships uniffi-bindgen on crates.io; contextgist-ffi
# builds its own via the "uniffi-bindgen-bin" feature (see
# crates/contextgist-ffi/uniffi-bindgen.rs). Install once with:
#   cargo install --path crates/contextgist-ffi --bin uniffi-bindgen \
#       --features uniffi-bindgen-bin --root ~/.cargo-uniffi-bindgen
# then add ~/.cargo-uniffi-bindgen/bin to PATH.
if command -v uniffi-bindgen &>/dev/null; then
    uniffi-bindgen generate --library "$BINDGEN_LIB" --language swift --out-dir "$GENERATED_DIR"
elif cargo uniffi-bindgen --help &>/dev/null 2>&1; then
    cargo uniffi-bindgen generate --library "$BINDGEN_LIB" --language swift --out-dir "$GENERATED_DIR"
else
    echo "uniffi-bindgen not found. See comment above this line for install steps."
    echo "Skipping binding generation — using existing generated files if present."
    exit 0
fi

echo "✓ Swift bindings written to $GENERATED_DIR/"
ls "$GENERATED_DIR/"
