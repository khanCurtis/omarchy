# Omarchy

Reproducible setup scripts and Omarchy overrides for my Arch-based development machine.

This repository does **not** contain dotfiles directly.
Dotfiles are managed in a separate repository and linked during install.

## Structure

suppliment/
├── install-all.sh          # Entry point
├── omarchy-overrides.conf  # Hyprland / Omarchy overrides
└── install/                # Modular install scripts
    └── installs.sh

## Usage

```bash
git clone https://github.com/<you>/omarchy-setup.git
cd omarchy-setup/suppliment
chmod +x install-all.sh install/*.sh
./install-all.sh
