#!/usr/bin/env bash
# remote-harness / preflight.sh
# Legacy/diagnostic prerequisite check for pre-simple flows. The current simple reverse/forward
# entry points do not call this script; they create session-local SSH config files and run their own
# targeted checks. Keep this helper for compatibility and focused debugging only.
#
#   preflight.sh [--alias <preferred>] [--project-dir <dir>]          # reverse (default)
#   preflight.sh --direction forward [--server '<ssh-args|alias>']    # forward
#
# reverse: legacy gate = a working reverse tunnel discoverable through an explicit alias or
# historical ~/.ssh/config loopback alias + local sshfs/FUSE. forward: gate = local sshfs/FUSE
# (+ server reachability if --server given). Both emit DIRECTION and PROJECT_DIR_EMPTY.
# It does NOT scan for the user's project — the flow asks the user to TYPE the path (see SKILL.md
# "ask, don't fish"); the compatibility `--no-list` flag is still accepted but is now a no-op.
#
# Output: KEY=VALUE on stdout. PREFLIGHT=ok|blocked. When blocked: BLOCKED_STEP + ERROR + REMEDY.
set -uo pipefail

RH="${RH_HOME:-$HOME/.remote-harness}"
SCRIPTS="$RH/scripts"; [ -x "$SCRIPTS/check-tunnel.sh" ] || SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

emit(){ printf '%s=%s\n' "$1" "$2"; }
blocked(){ emit PREFLIGHT blocked; emit BLOCKED_STEP "$1"; emit ERROR "$2"; emit REMEDY "$3"; exit 0; }
need_arg(){
  if [ -z "${2+x}" ] || [ -z "$2" ]; then
    printf 'missing value for %s\n' "$1" >&2
    exit 2
  fi
}

OS="$(uname -s 2>/dev/null || echo unknown)"
sshfs_install_hint(){   # the right install command for THIS machine's OS / package manager
  case "$OS" in
    Darwin) printf 'brew install macos-fuse-t/homebrew-cask/fuse-t && brew install macos-fuse-t/homebrew-cask/sshfs-fuse-t  (no kernel extension / no reduced security)';;
    *) if   command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y sshfs'
       elif command -v dnf     >/dev/null 2>&1; then printf 'sudo dnf install -y fuse-sshfs'
       elif command -v pacman  >/dev/null 2>&1; then printf 'sudo pacman -S --noconfirm sshfs'
       elif command -v zypper  >/dev/null 2>&1; then printf 'sudo zypper install -y sshfs'
       elif command -v apk     >/dev/null 2>&1; then printf 'sudo apk add sshfs'
       else printf "install 'sshfs' with your package manager"; fi;;
  esac
}
check_sshfs_fuse(){     # blocks on missing sshfs/FUSE; emits SSHFS/FUSE ok. Checks THIS machine.
  # Accept plain sshfs OR the macOS no-kext FUSE-T build (may install as sshfs-fuse-t).
  command -v sshfs >/dev/null 2>&1 || command -v sshfs-fuse-t >/dev/null 2>&1 || blocked sshfs \
    "sshfs is not installed on this machine." \
    "Run: $(sshfs_install_hint)"
  emit SSHFS ok
  # /dev/fuse is a Linux concept; macOS (macFUSE/FUSE-T) has no such device, so only check off-Darwin.
  if [ "$OS" != Darwin ] && [ ! -e /dev/fuse ]; then
    blocked sshfs "/dev/fuse is missing (FUSE not available)." \
      "Install/enable FUSE (e.g. install 'fuse3'; on WSL ensure the kernel exposes /dev/fuse)."
  fi
  emit FUSE ok
}

PREF_ALIAS="" PROJECT_DIR="$PWD" DIRECTION=reverse SERVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --alias)       need_arg "$1" "${2-}"; PREF_ALIAS="$2"; shift 2;;
    --project-dir) need_arg "$1" "${2-}"; PROJECT_DIR="$2"; shift 2;;
    --no-list)     shift;;                                            # compatibility no-op: preflight never scans for projects
    --direction)   need_arg "$1" "${2-}"; DIRECTION="$2"; shift 2;;   # reverse (default) | forward
    --server)      need_arg "$1" "${2-}"; SERVER="$2"; shift 2;;      # forward: ssh args/alias to the project server
    *) shift;;
  esac
done
case "$DIRECTION" in reverse|forward) ;; *) printf 'unsupported --direction %s\n' "$DIRECTION" >&2; exit 2;; esac

emit PROJECT_DIR "$PROJECT_DIR"
[ -n "${SSH_CONNECTION:-}" ] && emit ON_REMOTE 1 || emit ON_REMOTE 0

# ============================================================================
# FORWARD direction: local agent → project on a directly ssh-reachable server.
# No reverse tunnel; the gate is LOCAL sshfs/FUSE (+ server reachability if known).
# ============================================================================
if [ "$DIRECTION" = forward ]; then
  emit DIRECTION forward
  check_sshfs_fuse                                  # checks THIS (local) machine
  if [ -n "$SERVER" ]; then
    mkdir -p "$RH/.sessions" 2>/dev/null || true
    # $SERVER unquoted so raw args ("-p 2222 user@host") word-split; a bare alias is one word.
    if ssh -o "UserKnownHostsFile=$RH/.sessions/preflight-known_hosts" \
           -o GlobalKnownHostsFile=/dev/null \
           -o StrictHostKeyChecking=accept-new \
           -o ControlMaster=no -o ControlPath=none \
           -o BatchMode=yes -o ConnectTimeout=8 $SERVER true 2>/dev/null; then
      emit SERVER_REACHABLE 1
    else
      emit SERVER_REACHABLE 0
      emit SERVER_NOTE "couldn't key-auth to the server non-interactively (sshfs/builds may prompt for a password — set up an ssh key)"
    fi
  fi
  # Does the local invoking cwd work as the mountpoint? The simple flow's default mountpoint is
  # ~/.remote-harness/mounts/<project>.
  if [ -n "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]; then emit PROJECT_DIR_EMPTY 0
  else emit PROJECT_DIR_EMPTY 1; fi
  emit PREFLIGHT ok
  exit 0
fi
emit DIRECTION reverse

# ---- Step: reverse tunnel (the core gate) ----------------------------------
# With an explicit --alias (the real user's <RU>-mac), reuse ONLY that namespaced tunnel: on a
# SHARED box account, scanning every loopback alias could latch onto ANOTHER user's tunnel and mount
# the WRONG laptop. Without --alias (single-user / back-compat) scan all loopback aliases as before.
aliases=""
if [ -n "$PREF_ALIAS" ]; then
  aliases="$PREF_ALIAS"
elif [ -f "$HOME/.ssh/config" ]; then
  for a in $(awk 'tolower($1)=="host"{h=$2} tolower($1)=="hostname" && ($2=="127.0.0.1"||$2=="localhost"){print h}' "$HOME/.ssh/config"); do
    case " $aliases " in *" $a "*) ;; *) aliases="$aliases $a";; esac
  done
fi
aliases=$(printf '%s' "$aliases" | xargs 2>/dev/null || printf '%s' "$aliases")
[ -n "$aliases" ] || blocked tunnel \
  "No legacy reverse-tunnel ssh alias found for this diagnostic check." \
  "Use the simple bootstrap flow for normal sessions. For this legacy preflight only, pass --alias NAME for a session alias or run it in an environment that already has a loopback alias visible to ssh."

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
  "Use the simple bootstrap flow to recreate the session-local tunnel, or pass a known-good legacy alias with --alias."
emit TUNNEL_ALIAS "$OK_ALIAS"; emit TUNNEL_PORT "$OK_PORT"
emit LAPTOP_HOSTNAME "$LHOST"; emit LAPTOP_USER "$LUSER"

# ---- Step: sshfs + FUSE (on this box) --------------------------------------
check_sshfs_fuse

# ---- Step: project dir note (informational — laptop-setup.sh manages the mountpoint) ---
if [ -n "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]; then
  emit PROJECT_DIR_EMPTY 0
  emit PROJECT_DIR_NOTE "cwd is not empty — in the new flow that is fine; laptop-setup.sh creates the remote mountpoint automatically"
else
  emit PROJECT_DIR_EMPTY 1
fi

# ---- All clear -------------------------------------------------------------
emit PREFLIGHT ok
