#!/usr/bin/env bash
set -euo pipefail

if command -v ollama >/dev/null 2>&1; then
    echo "⚠ ollama is already installed. Skipping."
    exit 0
fi

sudo pacman -S --noconfirm ollama

