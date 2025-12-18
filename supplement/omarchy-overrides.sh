#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
OVERRIDE="$DIR/omarchy-overrides.conf"
HYPR_CONF="$HOME/.config/hypr/hyprland.conf"

if [ ! -f "$OVERRIDE" ]; then
  echo "❌ Overrides file not found at $OVERRIDE"
  exit 1
fi

if ! grep -Fxq "\nsource $OVERRIDE" "$HYPR_CONF"; then
  echo "source = $OVERRIDE" >> "$HYPR_CONF"
  echo "✅ Overrides sourced into $HYPR_CONF"
else
  echo "⚠ Overrides already sourced in $HYPR_CONF"
fi

