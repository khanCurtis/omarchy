#!/usr/bin/env bash
set -uo pipefail

GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

DIR="$(cd "$(dirname "$0")" && pwd)/supplement"
PID=""

abort() {
  echo -e "\n${RED}Installer aborted${NC}"
  [[ -n "$PID" ]] && kill -TERM -- "-$PID" 2>/dev/null
  exit 130
}

trap abort SIGINT SIGTERM

if ! command -v fzf >/dev/null; then
  echo -e "${RED}Please install fzf before running this script.${NC}"
  echo "sudo pacman -S fzf"
  exit 1
fi

mapfile -t SCRIPTS < <(
  find "$DIR" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' | sort
)

SELECTED=$(printf "%s\n" "${SCRIPTS[@]}" | \
  fzf --multi \
      --bind 'space:toggle,ctrl-a:select-all,ctrl-d:deselect-all' \
      --header "SPACE = toggle | Ctrl-a = select all | Ctrl-d = deselect | Enter = install"
)

[[ -z "$SELECTED" ]] && echo "Nothing selected, exiting..." && exit 0

echo
for script in $SELECTED; do
  echo -e "${GREEN}==> Installing $script${NC}"

  # Run in its own process group
  setsid bash "$DIR/$script" &
  PID=$!

  if ! wait "$PID"; then
    echo -e "${RED}✖ $script failed, continuing...${NC}"
  else
    echo -e "${GREEN}✓ $script completed${NC}"
  fi

  PID=""
  echo
done

echo -e "${GREEN}✅ All installs complete${NC}"

