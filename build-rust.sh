#!/bin/bash
# Builds the Rust FFI shim for iOS (device + Apple-Silicon simulator) and
# repackages StikPairFFI.xcframework. Run this whenever rust/ changes.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/rust"

echo "==> Building Rust static libs (release)"
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim

echo "==> Repackaging StikPairFFI.xcframework"
rm -rf "$ROOT/StikPairFFI.xcframework"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libstikpair_ffi.a -headers include \
  -library target/aarch64-apple-ios-sim/release/libstikpair_ffi.a -headers include \
  -output "$ROOT/StikPairFFI.xcframework"

echo "==> Done. (Re)generate the project with: xcodegen generate"
