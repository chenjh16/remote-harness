#!/usr/bin/env bash
# remote-harness / list-projects.sh
# List candidate project directories. In normal remote-harness use the projects live on the
# LAPTOP, so pass --via <ssh-alias> to scan there over the tunnel; without --via it scans
# this machine. Read-only. Prints "PROJECT\t<path>\t<git:branch|->" lines, then TOTAL/SHOWN.
set -uo pipefail

LIMIT=40
VIA=""
roots_args=""
while [ $# -gt 0 ]; do
  case "$1" in
    --via)   VIA="$2"; shift 2;;
    --root)  roots_args="$roots_args $2"; shift 2;;
    --limit) LIMIT="$2"; shift 2;;
    *) shift;;
  esac
done

# POSIX-sh scan, runs identically locally or on the laptop via `ssh <alias> sh -s`.
# Inputs via env: RH_LIMIT, RH_ROOTS (space-separated; empty => defaults under $HOME).
# NOTE: kept free of sed / single-quotes / "$#"-in-double-quotes so it survives transport.
SCAN='
LIMIT=${RH_LIMIT:-40}
set --
if [ -n "${RH_ROOTS:-}" ]; then
  for d in $RH_ROOTS; do [ -d "$d" ] && set -- "$@" "$d"; done
else
  for d in "$HOME" "$HOME/projects" "$HOME/Projects" "$HOME/code" "$HOME/src" \
           "$HOME/workspace" "$HOME/dev" "$HOME/repos" "$HOME/git" \
           "$HOME/Documents" "$HOME/TempCode" /workspace; do
    [ -d "$d" ] && set -- "$@" "$d"
  done
fi
[ $# -eq 0 ] && set -- "$HOME"
tmp=${TMPDIR:-/tmp}/.rh_all.$$
{
  for r in "$@"; do
    find "$r" -maxdepth 3 \
      \( -name node_modules -o -name .cache -o -name .venv -o -name vendor -o -name Library \) -prune -o \
      -type d -name .git -print 2>/dev/null
  done | while IFS= read -r g; do printf "%s\n" "${g%/.git}"; done
  for r in "$@"; do
    [ "$r" = "$HOME" ] && continue
    find "$r" -mindepth 1 -maxdepth 1 -type d 2>/dev/null
  done
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
'

if [ -n "$VIA" ]; then
  printf '%s' "$SCAN" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$VIA" \
    "RH_LIMIT=$LIMIT RH_ROOTS='$roots_args' sh -s"
else
  printf '%s' "$SCAN" | RH_LIMIT="$LIMIT" RH_ROOTS="$roots_args" sh -s
fi
