#!/usr/bin/env bash
set -e

cd ~

git clone https://github.com/khanCurtis/dotfiles.git
cd dotfiles

stow */

echo "Dotfiles successfully stowed"
