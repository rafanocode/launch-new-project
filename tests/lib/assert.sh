#!/usr/bin/env bash
# Tiny assertion helpers. Each increments FAILS on mismatch and prints context.
FAILS=0

assert_eq() { # <actual> <expected> <msg>
  if [ "$1" != "$2" ]; then
    echo "  FAIL: $3"; echo "    expected: [$2]"; echo "    actual:   [$1]"; FAILS=$((FAILS+1))
  else echo "  ok: $3"; fi
}

assert_contains() { # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) echo "  ok: $3" ;;
    *) echo "  FAIL: $3"; echo "    [$1] does not contain [$2]"; FAILS=$((FAILS+1)) ;;
  esac
}

assert_fail_exit() { # <exit_code> <msg>  — expects non-zero
  if [ "$1" -ne 0 ]; then echo "  ok: $2 (exit $1)"; else echo "  FAIL: $2 (expected non-zero, got 0)"; FAILS=$((FAILS+1)); fi
}
