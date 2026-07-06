#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/command/init-2env.md"
[ -f "$SRC" ] || { echo "sync: $SRC not found" >&2; exit 1; }
DEST_DIR="${CLAUDE_HOME:-$HOME/.claude}/commands"
mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST_DIR/init-2env.md"
echo "$DEST_DIR/init-2env.md"
