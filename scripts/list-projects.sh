#!/usr/bin/env bash
# remote-harness / list-projects.sh
# Opt-in helper to list candidate project directories. The default simple flows do not scan for
# projects; the user types the path locally and cached values are only prompt defaults. Pass
# --via <ssh-args|alias> to scan another SSH-reachable host; without --via it scans this machine.
# Read-only. Prints "PROJECT\t<path>\t<git:branch|->" lines, then TOTAL/SHOWN.
set -uo pipefail

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
need_arg() {
  if [ -z "${2+x}" ] || [ -z "$2" ]; then
    printf 'missing value for %s\n' "$1" >&2
    exit 2
  fi
}

LIMIT=40
VIA=""
roots_args=""
while [ $# -gt 0 ]; do
  case "$1" in
    --via)   need_arg "$1" "${2-}"; VIA="$2"; shift 2;;
    --root)  need_arg "$1" "${2-}"; roots_args="${roots_args}${roots_args:+
}$2"; shift 2;;
    --limit) need_arg "$1" "${2-}"; LIMIT="$2"; shift 2;;
    *) shift;;
  esac
done
printf '%s' "$LIMIT" | grep -qE '^[0-9]+$' || { printf 'limit must be numeric: %s\n' "$LIMIT" >&2; exit 2; }

# POSIX-sh scan, runs identically locally or on the laptop via `ssh <alias> sh -s`.
# Inputs via env: RH_LIMIT, RH_ROOTS (newline-separated; empty => defaults under $HOME).
# NOTE: kept free of sed / single-quotes / "$#"-in-double-quotes so it survives transport.
SCAN='
LIMIT=${RH_LIMIT:-40}
set --
if [ -n "${RH_ROOTS:-}" ]; then
  old_IFS=$IFS
  IFS="
"
  for d in $RH_ROOTS; do [ -d "$d" ] && set -- "$@" "$d"; done
  IFS=$old_IFS
else
  for d in "$HOME" "$HOME/projects" "$HOME/Projects" "$HOME/code" "$HOME/src" \
           "$HOME/workspace" "$HOME/dev" "$HOME/repos" "$HOME/git" \
           "$HOME/Documents" "$HOME/TempCode" /workspace; do
    [ -d "$d" ] && set -- "$@" "$d"
  done
fi
[ $# -eq 0 ] && set -- "$HOME"
rh_tmp="${RH_HOME:-$HOME/.remote-harness}/.sessions"
mkdir -p "$rh_tmp" 2>/dev/null || true
tmp=$(mktemp "$rh_tmp/rh-projects.XXXXXX" 2>/dev/null) || exit 1
trap "rm -f \"$tmp\"" EXIT HUP INT TERM
skip_dir() {
  # NOTE: use a private var name — `b`/`a`/`c`/`r` are the scan_projects loop vars,
  # and clobbering them here silently drops depth-2/3 repos.
  _skip_base=${1##*/}
  case "$_skip_base" in node_modules|.cache|.venv|vendor|Library) return 0;; *) return 1;; esac
}
emit_if_project() { [ -d "$1/.git" ] && printf "%s\n" "$1"; }
scan_projects() {
  r=$1
  emit_if_project "$r"
  for a in "$r"/* "$r"/.[!.]*; do
    [ -d "$a" ] || continue
    skip_dir "$a" && continue
    emit_if_project "$a"
    for b in "$a"/* "$a"/.[!.]*; do
      [ -d "$b" ] || continue
      skip_dir "$b" && continue
      emit_if_project "$b"
      for c in "$b"/* "$b"/.[!.]*; do
        [ -d "$c" ] || continue
        skip_dir "$c" && continue
        emit_if_project "$c"
      done
    done
  done
}
scan_children() {
  r=$1
  [ "$r" = "$HOME" ] && return 0
  for a in "$r"/* "$r"/.[!.]*; do [ -d "$a" ] && printf "%s\n" "$a"; done
}
{
  for r in "$@"; do scan_projects "$r"; done
  for r in "$@"; do scan_children "$r"; done
} | sort -u | grep -v "^$" > "$tmp"
total=$(wc -l < "$tmp" | tr -d " ")
n=0
while IFS= read -r p; do
  n=$((n+1)); [ $n -gt $LIMIT ] && break
  if [ -d "$p/.git" ]; then
    br=$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null) || br="(no commits)"
    br=$(printf "%s" "$br" | head -n1); [ -n "$br" ] || br="-"
    printf "PROJECT\t%s\tgit:%s\n" "$p" "$br"
  else
    printf "PROJECT\t%s\t-\n" "$p"
  fi
done < "$tmp"
printf "TOTAL=%s\n" "$total"
if [ "$total" -gt "$LIMIT" ]; then printf "SHOWN=%s (truncated; pass --root)\n" "$LIMIT"; else printf "SHOWN=%s\n" "$total"; fi
rm -f "$tmp" 2>/dev/null || true
trap - EXIT HUP INT TERM
'

if [ -n "$VIA" ]; then
  # $VIA is unquoted so a raw connect string ("-p 2222 user@host") word-splits into ssh args;
  # a bare alias is just one word. (Same convention as the setup scripts.)
  printf '%s' "$SCAN" | ssh -o BatchMode=yes -o ConnectTimeout=10 $VIA \
    "RH_LIMIT=$(sq "$LIMIT") RH_ROOTS=$(sq "$roots_args") sh -s"
else
  printf '%s' "$SCAN" | RH_LIMIT="$LIMIT" RH_ROOTS="$roots_args" sh -s
fi
