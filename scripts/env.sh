#!/usr/bin/env bash
# Source this file before development commands. No secrets are stored here.
HIYALL_TOOLS_DIR="${HIYALL_TOOLS_DIR:-$HOME/.local/share/hiyall-tools}"
export JAVA_HOME="$HIYALL_TOOLS_DIR/java"
export ANDROID_HOME="$HIYALL_TOOLS_DIR/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export RUSTUP_HOME="$HIYALL_TOOLS_DIR/rustup" CARGO_HOME="$HIYALL_TOOLS_DIR/cargo"
export PATH="$HIYALL_TOOLS_DIR/cargo/bin:$HIYALL_TOOLS_DIR/go-tools/bin:$HIYALL_TOOLS_DIR/go/bin:$HIYALL_TOOLS_DIR/flutter/bin:$HIYALL_TOOLS_DIR/node/bin:$HOME/.pub-cache/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$HIYALL_TOOLS_DIR/postgres/bin:$HIYALL_TOOLS_DIR/postgres-client/bin:$HIYALL_TOOLS_DIR/postgres/usr/lib/postgresql/16/bin:$PATH"
if [[ -x "$HIYALL_TOOLS_DIR/bin/cc" ]]; then
  export CC="$HIYALL_TOOLS_DIR/bin/cc" CGO_ENABLED=1
  # Rust links host binaries and build scripts with the same isolated compiler.
  export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="$HIYALL_TOOLS_DIR/bin/cc"
  export AR="$HIYALL_TOOLS_DIR/bin/ar"
fi
if [[ "$(uname -s)" == "Linux" ]]; then
  export LD_LIBRARY_PATH="$HIYALL_TOOLS_DIR/postgres/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
