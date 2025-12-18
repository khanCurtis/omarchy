#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd")"

echo "Installing all..."

for script in "$DIR"/*.sh; do
  [[ "$(basename "$script")" == install-all.sh ]] && continue

  echo "-> Installing $(basename "$script")"
  chmod =x "$script"
  ./"$script"
done

echo "✅ All installs complete"

