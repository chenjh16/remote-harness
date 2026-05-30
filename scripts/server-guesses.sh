#!/usr/bin/env bash
# remote-harness / server-guesses.sh — read-only. For the FORWARD direction (local agent → project
# on a remote server), suggest OUTBOUND ssh targets for the skill to offer the user. Prints one
# candidate `ssh <target>` per line on stdout (most-likely first, deduped); a NOTE on stderr.
# The user's own answer is authoritative — these are only hints.
set -uo pipefail

CFG="$HOME/.ssh/config"; KH="$HOME/.ssh/known_hosts"

# Loopback aliases (HostName 127.0.0.1/localhost) are reverse-harness tunnels — exclude them from
# ALL sources (history/known_hosts could otherwise resurface a tunnel alias as a "server").
LOOPBACK="$(awk '
  function flush(){ if(loop) for(i=1;i<=n;i++) print cur[i] }
  tolower($1)=="host"{ flush(); n=0; loop=0; for(i=2;i<=NF;i++) if($i!~/[*?]/) cur[++n]=$i; next }
  tolower($1)=="hostname" && ($2=="127.0.0.1"||$2=="localhost"){ loop=1 }
  END{ flush() }' "$CFG" 2>/dev/null)"
{
  # 1) ~/.ssh/config Host aliases — strongest signal (they carry user/port/identity). EXCLUDE
  #    loopback aliases (HostName 127.0.0.1/localhost) — those are reverse-harness tunnels.
  if [ -f "$CFG" ]; then
    awk '
      function flush(){ if(!loop) for(i=1;i<=n;i++) print cur[i] }
      tolower($1)=="host"{ flush(); n=0; loop=0; for(i=2;i<=NF;i++) if($i!~/[*?]/) cur[++n]=$i; next }
      tolower($1)=="hostname" && ($2=="127.0.0.1"||$2=="localhost"){ loop=1 }
      END{ flush() }' "$CFG" 2>/dev/null
  fi
  # 2) recent simple `ssh host` / `ssh user@host` from shell history (best-effort).
  for hist in "$HOME/.bash_history" "$HOME/.zsh_history"; do
    [ -f "$hist" ] || continue
    grep -hoE '(^|[;&] )ssh +[A-Za-z0-9._@-]+' "$hist" 2>/dev/null | sed -E 's/.*ssh +//' | tail -50
  done
  # 3) known_hosts hostnames (skip hashed entries; strip [host]:port and comma lists; drop loopback).
  if [ -f "$KH" ]; then
    awk '$1 !~ /^\|/{print $1}' "$KH" 2>/dev/null | tr ',' '\n' \
      | sed -E 's/^\[([^]]+)\]:[0-9]+$/\1/' | grep -vE '^(127\.|localhost$|::1$|$)'
  fi
} | awk -v bad="$LOOPBACK" '
    BEGIN{ nb=split(bad,b,"\n"); for(i=1;i<=nb;i++) if(b[i]!="") skip[b[i]]=1 }
    NF && $0 !~ /[*?]/ && !(($0) in skip) && !seen[$0]++ {print "ssh " $0}'

printf 'NOTE: guesses only — pick one or type your own `ssh ...` to the server.\n' >&2
