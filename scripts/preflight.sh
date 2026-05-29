#!/usr/bin/env bash
# remote-harness / preflight.sh
# ONE-SHOT prerequisite check for the mount flow — replaces running detect.sh + check-tunnel.sh
# + the empty-dir check as separate agent round-trips. Runs every check in a single process,
# STOPS at the first blocker with a detailed ERROR + REMEDY, and (when all pass) also lists the
# laptop's candidate project dirs so the agent can go straight to directory selection.
#
#   preflight.sh [--alias <preferred>] [--project-dir <dir>] [--no-list]
#
# Output: KEY=VALUE on stdout. PREFLIGHT=ok|blocked. When blocked: BLOCKED_STEP + ERROR + REMEDY.
# When ok and listing: a line "---PROJECTS---" followed by list-projects.sh output.
set -uo pipefail

RH="${RH_HOME:-$HOME/.remote-harness}"
SCRIPTS="$RH/scripts"; [ -x "$SCRIPTS/check-tunnel.sh" ] || SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

emit(){ printf '%s=%s\n' "$1" "$2"; }
blocked(){ emit PREFLIGHT blocked; emit BLOCKED_STEP "$1"; emit ERROR "$2"; emit REMEDY "$3"; exit 0; }

PREF_ALIAS="" PROJECT_DIR="$PWD" NO_LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --alias)       PREF_ALIAS="$2"; shift 2;;
    --project-dir) PROJECT_DIR="$2"; shift 2;;
    --no-list)     NO_LIST=1; shift;;
    *) shift;;
  esac
done

emit PROJECT_DIR "$PROJECT_DIR"
[ -n "${SSH_CONNECTION:-}" ] && emit ON_REMOTE 1 || emit ON_REMOTE 0

# ---- Step: reverse tunnel (the core gate) ----------------------------------
aliases=""
[ -n "$PREF_ALIAS" ] && aliases="$PREF_ALIAS"
if [ -f "$HOME/.ssh/config" ]; then
  for a in $(awk 'tolower($1)=="host"{h=$2} tolower($1)=="hostname" && ($2=="127.0.0.1"||$2=="localhost"){print h}' "$HOME/.ssh/config"); do
    case " $aliases " in *" $a "*) ;; *) aliases="$aliases $a";; esac
  done
fi
aliases=$(printf '%s' "$aliases" | xargs 2>/dev/null || printf '%s' "$aliases")
[ -n "$aliases" ] || blocked tunnel \
  "No reverse-tunnel ssh alias found (no 'Host ... HostName 127.0.0.1' in ~/.ssh/config)." \
  "Set up the tunnel first (Step 1: setup-tunnel.sh + add the RemoteForward line on the laptop and reconnect), then re-run preflight."

OK_ALIAS="" OK_PORT="" LHOST="" LUSER="" last_err=""
for a in $aliases; do
  out=$("$SCRIPTS/check-tunnel.sh" --alias "$a" 2>/dev/null || true)
  if printf '%s\n' "$out" | grep -q '^SSH=up'; then
    OK_ALIAS="$a"
    OK_PORT=$(printf '%s\n' "$out" | awk -F= '$1=="PORT"{print $2}')
    LHOST=$(printf '%s\n' "$out" | awk -F= '$1=="LAPTOP_HOSTNAME"{print $2}')
    LUSER=$(printf '%s\n' "$out" | awk -F= '$1=="LAPTOP_USER"{print $2}')
    break
  fi
  last_err=$(printf '%s\n' "$out" | awk -F= '$1=="ERROR"{print $2}')
done
[ -n "$OK_ALIAS" ] || blocked tunnel \
  "Tunnel alias(es) [$aliases] exist but none reach the laptop (SSH=down). last error: ${last_err:-n/a}" \
  "On the laptop ensure 'RemoteForward <port> 127.0.0.1:22' is set for the host you use, then RECONNECT (kill a stale master with 'ssh -O exit <host>'). Re-run preflight."
emit TUNNEL_ALIAS "$OK_ALIAS"; emit TUNNEL_PORT "$OK_PORT"
emit LAPTOP_HOSTNAME "$LHOST"; emit LAPTOP_USER "$LUSER"

# ---- Step: sshfs + FUSE ----------------------------------------------------
command -v sshfs >/dev/null 2>&1 || blocked sshfs \
  "sshfs is not installed on this box." \
  "Run (needs sudo): sudo apt-get install -y sshfs"
emit SSHFS ok
[ -e /dev/fuse ] || blocked sshfs \
  "/dev/fuse is missing (FUSE not available)." \
  "Install/enable FUSE (e.g. install 'fuse3'; on WSL ensure the kernel exposes /dev/fuse)."
emit FUSE ok

# ---- Step: empty project dir ----------------------------------------------
if [ -n "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]; then
  emit PROJECT_DIR_EMPTY 0
  blocked project-dir \
    "Project dir is NOT empty: $PROJECT_DIR (mounting would hide its contents)." \
    "Launch Claude Code in a fresh EMPTY dir for this project (mkdir -p ~/work/<name> && cd ~/work/<name> && claude), then re-run."
fi
emit PROJECT_DIR_EMPTY 1

# ---- All clear -------------------------------------------------------------
emit PREFLIGHT ok
if [ "$NO_LIST" != 1 ]; then
  echo "---PROJECTS---"
  "$SCRIPTS/list-projects.sh" --via "$OK_ALIAS"
fi
