#!/usr/bin/env bash
set -euo pipefail

DEST="${1:-$HOME/.codex/skills/sol-devnet}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$(dirname "$DEST")"

if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude '.git' \
    --exclude '.sol-devnet' \
    --exclude '.sol-devnet-miner' \
    "$SOURCE_DIR/" "$DEST/"
else
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp -R "$SOURCE_DIR"/. "$DEST"/
  rm -rf "$DEST/.git" "$DEST/.sol-devnet" "$DEST/.sol-devnet-miner"
fi

chmod +x "$DEST"/scripts/*.sh
echo "Installed sol-devnet to: $DEST"
