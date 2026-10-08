#!/usr/bin/env bash
# Source this file before development commands. No secrets are stored here.
KAIROVA_TOOLS_DIR="${KAIROVA_TOOLS_DIR:-$HOME/.local/share/kairova-tools}"
export JAVA_HOME="$KAIROVA_TOOLS_DIR/java"
export ANDROID_HOME="$KAIROVA_TOOLS_DIR/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export RUSTUP_HOME="$KAIROVA_TOOLS_DIR/rustup" CARGO_HOME="$KAIROVA_TOOLS_DIR/cargo"
export PATH="$KAIROVA_TOOLS_DIR/cargo/bin:$KAIROVA_TOOLS_DIR/go-tools/bin:$KAIROVA_TOOLS_DIR/go/bin:$KAIROVA_TOOLS_DIR/flutter/bin:$KAIROVA_TOOLS_DIR/node/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$KAIROVA_TOOLS_DIR/postgres/usr/lib/postgresql/16/bin:$PATH"
if [[ -x "$KAIROVA_TOOLS_DIR/bin/cc" ]]; then
  export CC="$KAIROVA_TOOLS_DIR/bin/cc" CGO_ENABLED=1
  # Rust links host binaries and build scripts with the same isolated compiler.
  export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="$KAIROVA_TOOLS_DIR/bin/cc"
  export AR="$KAIROVA_TOOLS_DIR/bin/ar"
fi
export LD_LIBRARY_PATH="$KAIROVA_TOOLS_DIR/postgres/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
