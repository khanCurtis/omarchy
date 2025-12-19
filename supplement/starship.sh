#!/usr/bin/env bash
set -e

sudo pacman -S --noconfirm starship

if ! grep -q "starship init zsh" ~/.zshrc 2>/dev/nul; then
  echo 'eval "$(starship init zsh)"' >> ~/.zshrc
fi

