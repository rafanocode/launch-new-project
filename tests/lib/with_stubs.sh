#!/usr/bin/env bash
# make_stub writes an executable fake CLI into $STUB_BIN (must be on PATH).
# Usage: make_stub gh 'echo "stub gh $*"; exit 0'
make_stub() { # <name> <body>
  local name="$1" body="$2"
  { echo '#!/usr/bin/env bash'; echo "$body"; } > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}
