#!/usr/bin/env bash
set -euo pipefail

if command -v rustup >/dev/null 2>&1; then
    echo "⚠ rustup is already installed. Skipping."
    exit 0
fi

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
export PATH="$HOME/.cargo/bin:$PATH"

sudo pacman -S --noconfirm rustup

rustup componant add clippy rustfmt rust-analyzer rust-src

cargo install cargo-watch cargo-edit cargo-audit cargo-outdated cargo-fuzz cargo-tarpaulin cargo-geiger
