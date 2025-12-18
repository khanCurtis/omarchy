#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "$0")/supplement" && pwd)"

cd "$DIR"

if ! command -v fzf >/dev/null; then
  sudo pacman -S --noconfirm fzf
fi

scripts=$(printf "%s\n" *.sh | sort)

selected=$(echo "$scripts" | fzf \
  --multi \
  --prompt="Select install scripts > " \
  --header="TAB = select | ENTER = run" \
)

[ -z "$selected" ] && exit 0

echo "Running selected installations..."
for script in $selected; do
  echo "-> Installing $script"
  chmod +x "$script"
  ./"$script"
done

echo "✅ All installs complete"
