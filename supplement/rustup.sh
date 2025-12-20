#!/usr/bin/env bash
set -euo pipefail

if command -v rustup >/dev/null 2>&1; then
    echo "⚠ rustup is already installed. Skipping."
    exit 0
fi

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

export PATH="$HOME/.cargo/bin:$PATH"

