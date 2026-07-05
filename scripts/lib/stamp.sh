#!/usr/bin/env bash
# Render {{VAR}} markers from environment variables. Fails if any remain.
stamp_file() { # <template> <output>
  local tpl="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  perl -pe 's/\{\{(\w+)\}\}/exists $ENV{$1} ? $ENV{$1} : "{{$1}}"/ge' "$tpl" > "$out"
  if grep -q '{{[A-Za-z0-9_]\{1,\}}}' "$out"; then
    { echo "stamp: unresolved markers in $out:"; grep -o '{{[A-Za-z0-9_]\{1,\}}}' "$out" | sort -u; } >&2
    return 1
  fi
}

stamp_dir() { # <src_dir> <dest_dir>
  local src="$1" dest="$2" f rel
  while IFS= read -r f; do
    rel="${f#"$src"/}"
    stamp_file "$f" "$dest/$rel" || return 1
  done < <(find "$src" -type f)
}
