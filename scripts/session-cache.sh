#!/usr/bin/env bash
# remote-harness / session-cache.sh — remember a namespace's last connection choices on THIS machine
# so a RE-RUN can recommend them instantly, with ZERO remote discovery (no project scan, no ssh-find).
# Realizes the "keep historical connection info" idea: per-namespace KEY=VALUE file under
# $RH_HOME/.sessions-cache/<key>.env (mode 600). Direction-neutral — reverse keys by the real-user
# namespace RU, forward keys by the server token.
#
#   session-cache.sh put <key> KEY=VALUE [KEY=VALUE ...]   # store (atomic; ignores malformed pairs)
#   session-cache.sh get <key>                             # print stored KEY=VALUE lines (none if absent)
#
# The agent calls `get` during its single local probe (to pre-fill the questions) and `put` right
# before emitting the final command. Read-only `get` never fails the flow.
set -uo pipefail

RH="${RH_HOME:-$HOME/.remote-harness}"
DIR="$RH/.sessions-cache"

# Map a namespace key to its cache file, sanitizing it to a safe single filename component.
key_file() {
  k="$(printf '%s' "${1:-}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  case "$k" in ""|.|..) return 1;; esac
  printf '%s/%s.env' "$DIR" "$k"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  get)
    f="$(key_file "${1:-}")" || exit 0
    [ -f "$f" ] && cat "$f" 2>/dev/null || true
    ;;
  put)
    f="$(key_file "${1:-}")" || { printf 'ERROR=bad key\n' >&2; exit 2; }
    [ $# -gt 0 ] && shift
    mkdir -p "$DIR" 2>/dev/null || true; chmod 700 "$DIR" 2>/dev/null || true
    tmp="$(mktemp "${TMPDIR:-/tmp}/rh-cache.XXXXXX")" || { printf 'ERROR=mktemp\n' >&2; exit 1; }
    for kv in "$@"; do
      case "$kv" in
        *'
'*) ;;                              # skip values with newlines (would corrupt the line format)
        [A-Za-z_]*=*) printf '%s\n' "$kv" >> "$tmp";;   # keep only well-formed KEY=VALUE pairs
      esac
    done
    if mv "$tmp" "$f" 2>/dev/null; then chmod 600 "$f" 2>/dev/null || true; printf 'STATUS=saved\n'
    else rm -f "$tmp" 2>/dev/null || true; printf 'ERROR=write-failed\n' >&2; exit 1; fi
    ;;
  *)
    printf 'usage: session-cache.sh get <key> | put <key> KEY=VALUE...\n' >&2; exit 2;;
esac
