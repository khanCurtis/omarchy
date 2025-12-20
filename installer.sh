#!/usr/bin/env bash
set -euo pipefail

GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
NC='\e[0m'

DIR="$(cd "$(dirname "$0")" && pwd)/supplement"

# Prompt for sudo password once
read -s -p "Enter your sudo password: " SUDOPASS
echo

trap 'echo -e "${RED}\nInstaller aborted${NC}"; exit 130' SIGINT SIGTERM

if ! command -v fzf >/dev/null; then
  echo -e "${RED}Please install fzf first${NC}"
  exit 1
fi

# Find install scripts
mapfile -t SCRIPTS < <(find "$DIR" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' | sort)

SELECTED=$(printf "%s\n" "${SCRIPTS[@]}" | \
  fzf --multi \
      --bind 'space:toggle,ctrl-a:select-all,ctrl-d:deselect-all' \
      --header "SPACE = toggle | ctrl+a = select all | ctrl+d = deselect all | Enter = install"
)

[[ -z "$SELECTED" ]] && echo "Nothing selected, exiting..." && exit 0

echo "Installing:"
echo

# Track status
declare -A STATUS

for script in $SELECTED; do
  PACKAGE_NAME="${script%.sh}"
  echo -e "${GREEN}==> Installing $PACKAGE_NAME${NC}"

  # Check if package is already installed
  if pacman -Qi "$PACKAGE_NAME" &>/dev/null; then
    echo -e "${YELLOW}⚠ $PACKAGE_NAME is already installed, skipping.${NC}"
    STATUS["$PACKAGE_NAME"]="skipped"
    continue
  fi

  # Run script
  if echo "$SUDOPASS" | sudo -S bash "$DIR/$script"; then
    echo -e "${GREEN}✔ $PACKAGE_NAME installed successfully${NC}"
    STATUS["$PACKAGE_NAME"]="success"
  else
    echo -e "${RED}✖ $PACKAGE_NAME failed, continuing...${NC}"
    STATUS["$PACKAGE_NAME"]="failed"
  fi
done

# Summarize
failed_count=0
success_count=0
skipped_count=0

for s in "${STATUS[@]}"; do
  case "$s" in
    failed) ((failed_count++)) ;;
    success) ((success_count++)) ;;
    skipped) ((skipped_count++)) ;;
  esac
done

echo
if ((failed_count == 0)); then
  echo -e "${GREEN}✅ All installs complete${NC}"
elif ((success_count == 0)); then
  echo -e "${RED}❌ All installs failed${NC}"
else
  echo -e "${YELLOW}⚠ Some installs failed during installation process${NC}"
fi

