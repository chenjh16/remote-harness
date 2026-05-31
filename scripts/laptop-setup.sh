#!/usr/bin/env bash
# remote-harness / laptop-setup.sh — run ON YOUR LAPTOP.
#
# Full flow (all in one command, no editing required):
#   Phase 1 — Ensure SSH server on, authorize the box's key, write RemoteForward to ~/.ssh/config
#   Phase 2 — Reconnect automatically (establishes the reverse tunnel)
#   Phase 3 — Pick a project dir on THIS laptop (readline prompt, defaults to cwd)
#   Phase 4 — Mount the chosen dir on the remote box via sshfs (over the tunnel)
#   Phase 5 — Launch the chosen agent (claude/codex/opencode) on the box in the mounted dir (ssh -t)
#
# Usage (emitted by the skill — paste as-is). This script sources _common.sh from beside it, so the
# command fetches BOTH files into one temp dir (the laptop usually has no install):
#   d=$(mktemp -d "${TMPDIR:-/tmp}/rh.XXXXXX") \
#     && ssh <CONNECT> 'cat ~/.remote-harness/scripts/_common.sh'      >"$d/_common.sh" \
#     && ssh <CONNECT> 'cat ~/.remote-harness/scripts/laptop-setup.sh' >"$d/laptop-setup.sh" \
#     && bash "$d/laptop-setup.sh" --host <HOST> --port <PORT> --via '<CONNECT>' --box-alias <ALIAS>
#     ; rm -rf "$d"
#
# Flags:
#   --host <alias|ip>     ssh Host block to write/update (required)
#   --port <PORT>         RemoteForward port on the remote (required)
#   --via <ssh-args>      exact ssh args to reach the box (e.g. "-p 2222 user@1.2.3.4")
#   --box-alias <name>    alias the BOX uses to reach back to this laptop (default: <user>-mac)
#   --pubkey <key>        box public key to authorize (fetched via --via if omitted)
#   --box-user <user>     remote box username (for mount path and alias naming)
#   --remote-mountpoint <d>  exact box dir to mount the project at (must be empty;
#                            default: <remote $HOME>/work/<project-name>)
#   --project-dir <d>     laptop project dir to mount (skips Phase 3's interactive prompt)
#   --launch <cmd>        coding-agent CLI to start on the remote (default: claude;
#                         Codex passes 'codex', opencode passes 'opencode')
#   --yolo                bypass approvals on the launched agent — claude/codex get their
#                         bypass flag; opencode gets a temporary permission=allow config (restored)
#   --setup-only          stop after Phase 1 — skip reconnect / dir-pick / mount / launch
#   --yes                 non-interactive (skip all confirm prompts)
set -uo pipefail

# ---- argument parsing -----------------------------------------------------
HOST="" PORT="" PUBKEY="" VIA="" BOX_ALIAS="" ASSUME_YES=0 SETUP_ONLY=0
BOX_USER="" REMOTE_MP="" LAUNCH="claude" PROJ_DIR_ARG=""
YOLO=0; EFF_LAUNCH=""; LAUNCH_BASE="claude"
while [ $# -gt 0 ]; do
  case "$1" in
    --host)          HOST="$2";           shift 2;;
    --port)          PORT="$2";           shift 2;;
    --pubkey)        PUBKEY="$2";         shift 2;;
    --via)           VIA="$2";            shift 2;;
    --launch)        LAUNCH="$2";         shift 2;;   # CLI to start on the remote (claude/codex/opencode)
    --yolo)          YOLO=1;              shift;;     # bypass approvals on the launched agent
    --box-alias)     BOX_ALIAS="$2";      shift 2;;
    --box-user)      BOX_USER="$2";       shift 2;;
    --remote-mountpoint) REMOTE_MP="$2";  shift 2;;   # exact box dir to mount at (e.g. your invoking cwd)
    --project-dir)   PROJ_DIR_ARG="$2";   shift 2;;   # laptop project dir (skip the interactive prompt)
    --setup-only)    SETUP_ONLY=1;        shift;;
    --yes|-y)        ASSUME_YES=1;        shift;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
  esac
done
[ -n "$PORT" ] || { printf 'need --port\n' >&2; exit 2; }
printf '%s' "$PORT" | grep -qE '^[0-9]+$' || { printf 'port must be numeric: %s\n' "$PORT" >&2; exit 2; }

# ---- shared helpers (colors, say/ok/warn/err/hdr/ask, sq, OS vars, parse_via, ssh-config) -------
# laptop-setup.sh is fetched to the laptop and run STANDALONE (the laptop usually has no install),
# so the skill's one-command fetches _common.sh next to this file and we source it by path.
RH_COMMON="${RH_COMMON:-$(dirname "$0")/_common.sh}"
if [ -f "$RH_COMMON" ]; then . "$RH_COMMON"
else printf 'error: missing _common.sh next to %s — re-copy the full command\n' "$0" >&2; exit 2; fi

# ---- auto-cleanup on exit/disconnect ---------------------------------------
TUNNEL_PID=""; MOUNTED=0; CLEANED=0; RULE_INJECTED=0
cleanup() {
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  if [ "$MOUNTED" = 1 ]; then
    printf '\n'
    say "  Connection closed — auto-unmounting ${REMOTE_MOUNTPOINT:-} on the remote box..."
    ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "${TARGET:-}" "
      rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
      \"\$rh/scripts/mount-project.sh\" --alias $(sq "${BOX_ALIAS:-}") --unmount --mountpoint $(sq "${REMOTE_MOUNTPOINT:-}")
    " >/dev/null 2>&1 && ok "Unmounted" || warn "auto-unmount failed — mount may be stale on the box (next run re-validates it)"
  fi
  if [ "${RULE_INJECTED:-0}" = 1 ]; then
    ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "${TARGET:-}" \
      "\"\${RH_HOME:-\$HOME/.remote-harness}/scripts/inject-rule.sh\" off $(sq "${LAUNCH_BASE:-claude}") $(sq "${REMOTE_MOUNTPOINT:-}")" >/dev/null 2>&1 \
      && ok "session-scoped rule + temp config removed" || true
  fi
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
}

# OS vars (OS/PLAT/IS_WSL) come from _common.sh.
printf "\n${_B}remote-harness${_0} laptop setup  ${_C}port=%s${_0}  platform=%s\n\n" "$PORT" "$PLAT"

# Resolve YOLO into the effective launch command per agent.
EFF_LAUNCH="$LAUNCH"
LAUNCH_BASE="$(set -- $LAUNCH; echo "${1:-claude}")"   # bare CLI name (claude|codex|opencode)
case "$LAUNCH_BASE" in
  claude|codex|opencode) ;;
  *) printf 'unsupported --launch %s (expected claude|codex|opencode)\n' "$LAUNCH" >&2; exit 2;;
esac
if [ "$YOLO" = 1 ]; then
  case "$LAUNCH_BASE" in
    claude)   EFF_LAUNCH="$LAUNCH --dangerously-skip-permissions";              warn "YOLO: claude --dangerously-skip-permissions";;
    codex)    EFF_LAUNCH="$LAUNCH --dangerously-bypass-approvals-and-sandbox";  warn "YOLO: codex --dangerously-bypass-approvals-and-sandbox";;
    opencode) warn "YOLO: opencode permission=allow (set in this session's config only — nothing global)";;
    *)        warn "YOLO requested but unknown agent '$LAUNCH' — launching without bypass";;
  esac
fi

# ===========================================================================
# Phase 1: SSH server, authorized key, RemoteForward in ~/.ssh/config
# ===========================================================================

# -- parse --via into V_HOST/V_PORT/V_USER/V_IDENTITY (parse_via from _common.sh) --
parse_via "$VIA"
[ -z "$V_HOST" ] && [ -n "$HOST" ] && V_HOST="$HOST"
[ -z "$BOX_USER" ] && BOX_USER="$V_USER"

# -- obtain the box's public key --
if [ -z "$PUBKEY" ]; then
  KCMD='cat ~/.remote-harness/.tunnel-pubkey 2>/dev/null || cat ~/.ssh/id_ed25519.pub 2>/dev/null'
  if [ -n "$VIA" ]; then
    # $VIA is intentionally unquoted so it word-splits into ssh args; NOT eval'd (avoids running
    # shell metacharacters in a mistyped/crafted connect string locally).
    PUBKEY="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 $VIA "$KCMD" 2>/dev/null || true)"
  elif [ -n "$HOST" ]; then
    PUBKEY="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$KCMD" 2>/dev/null || true)"
  fi
  PUBKEY="$(printf '%s' "$PUBKEY" | sed -n '1p')"
fi
[ -n "$PUBKEY" ] && ok "box key: $(printf '%s' "$PUBKEY" | awk '{print $1, substr($2,1,14)"...", $3}')" \
                 || warn "no box key found — authorized_keys step will be skipped"

# -- ensure SSH server running --
ssh_listening() { (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null && { exec 3>&-; return 0; }; return 1; }
if ssh_listening; then
  ok "SSH server: listening on :22"
else
  if [ "$PLAT" = macos ]; then
    ask "  SSH server (Remote Login) seems OFF. Enable it?" && \
      { sudo systemsetup -setremotelogin on && ok "Remote Login ON" \
        || warn "enable in System Settings > General > Sharing > Remote Login"; }
  else
    if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
      for pm in "apt-get:-y openssh-server" "dnf:-y openssh-server" "pacman:--noconfirm openssh" "apk: openssh"; do
        cmd="${pm%%:*}"; args="${pm#*:}"
        if command -v "$cmd" >/dev/null 2>&1; then
          ask "  sshd not found. Install via $cmd?" && eval "sudo $cmd install $args" && break
        fi
      done
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      ask "  Enable & start ssh (sudo systemctl enable --now ssh)?" && \
        { sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd 2>/dev/null; }
    elif command -v service >/dev/null 2>&1; then
      # No systemd (common on WSL / OpenRC / SysV) — fall back to the service wrapper.
      ask "  Start ssh (sudo service ssh start)?" && \
        { sudo service ssh start 2>/dev/null || sudo service sshd start 2>/dev/null; }
    elif [ -x /etc/init.d/ssh ] || [ -x /etc/init.d/sshd ]; then
      ask "  Start ssh (sudo /etc/init.d/ssh start)?" && \
        { sudo /etc/init.d/ssh start 2>/dev/null || sudo /etc/init.d/sshd start 2>/dev/null; }
    fi
  fi
  ssh_listening && ok "SSH server: listening" \
                || warn "still not listening on :22 — the tunnel won't work without it"
fi

# -- authorize box key --
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh" 2>/dev/null || true
AK="$HOME/.ssh/authorized_keys"; touch "$AK"; chmod 600 "$AK" 2>/dev/null || true
if [ -n "$PUBKEY" ]; then
  keybody="$(printf '%s' "$PUBKEY" | awk '{print $1" "$2}')"
  if grep -qF "$keybody" "$AK" 2>/dev/null; then ok "authorized_keys: box key already present"
  else printf '%s\n' "$PUBKEY" >> "$AK"; ok "authorized_keys: added box key"; fi
fi

# -- write RemoteForward to ~/.ssh/config --
CFG="$HOME/.ssh/config"; touch "$CFG"; chmod 600 "$CFG" 2>/dev/null || true
TARGET=""; REUSE=0   # block_exists / remove_host_block / write_managed_alias come from _common.sh

# The --via connection is the GROUND TRUTH for how to reach the box. If it carries an explicit
# user or port (a raw connection like `-p 2222 user@ip`), reach the box through a DEDICATED managed
# alias built from those exact params — NEVER by writing RemoteForward into a coincidental/stale
# `Host <ip>` block, which may resolve to the wrong user/port (e.g. defaulting to the laptop's own
# username, leaving the tunnel asking for a password). Only reuse --host when --via IS just that alias.
RAW_CONN=0; { [ -n "$V_PORT" ] || [ -n "$V_USER" ]; } && RAW_CONN=1
if [ "$RAW_CONN" = 0 ] && [ -n "$HOST" ] && block_exists "$HOST"; then
  TARGET="$HOST"; REUSE=1
else
  TARGET="${BOX_USER:-${V_USER:-box}}-remote"
fi
cp "$CFG" "$CFG.rh-bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)" 2>/dev/null || true
RF_LINE="    RemoteForward $PORT 127.0.0.1:22"
if [ "$REUSE" = 1 ]; then
  tmp="$(mktemp)"
  # Insert RemoteForward + tunnel keepalives into the user's existing alias block, de-duping our own
  # managed lines first so re-runs stay idempotent (use 'hit' not 'in' — reserved in BSD awk). The
  # keepalives mirror the managed-alias branch so a reused alias detects a half-open NAT tunnel and
  # fails loudly on a port collision instead of leaving a live-but-no-forward connection.
  if awk -v host="$TARGET" -v rf="$RF_LINE" \
      -v o1="    ServerAliveInterval 30" -v o2="    ServerAliveCountMax 3" \
      -v o3="    ExitOnForwardFailure yes" -v o4="    TCPKeepAlive yes" '
    function H(s){return s~/^[ \t]*[Hh][Oo][Ss][Tt][ \t]/}
    BEGIN{hit=0}
    {if(H($0)){hit=0;n=split($0,a,/[ \t]+/);for(i=1;i<=n;i++){if(a[i]=="#")break;if(i>1&&a[i]==host)hit=1}
     print;if(hit){print rf;print o1;print o2;print o3;print o4}next}
     if(hit&&$0~/^[ \t]*RemoteForward[ \t]+[0-9]+[ \t]+127\.0\.0\.1:22[ \t]*$/)next
     if(hit&&$0~/^[ \t]*(ServerAliveInterval|ServerAliveCountMax|ExitOnForwardFailure|TCPKeepAlive)([ \t]|$)/)next
     print}' "$CFG" > "$tmp" && mv "$tmp" "$CFG"; then
    ok "ssh config: added RemoteForward $PORT + keepalives inside existing 'Host $TARGET'"
  else
    warn "ssh config: awk edit failed — add '$RF_LINE' under 'Host $TARGET' manually"; rm -f "$tmp"
  fi
else
  # Create-or-replace a managed alias carrying the exact --via identity + RemoteForward (idempotent).
  # Keepalives so a half-open tunnel (NAT idle / laptop sleep) is detected; ExitOnForwardFailure so a
  # port-collision fails loudly instead of leaving a live-but-no-forward connection that polls as "up".
  write_managed_alias "$TARGET" "$RF_LINE" \
    "    ServerAliveInterval 30" "    ServerAliveCountMax 3" \
    "    ExitOnForwardFailure yes" "    TCPKeepAlive yes"
  ok "ssh config: wrote managed 'Host $TARGET' (HostName ${V_HOST:-?}, port ${V_PORT:-22}, user ${V_USER:-<login default>}) + RemoteForward"
  say "    Reconnect to the box via: ${_B}ssh $TARGET${_0}"
fi
chmod 600 "$CFG" 2>/dev/null || true

# -- default box-alias --
if [ -z "$BOX_ALIAS" ]; then
  LUSER=$(id -un 2>/dev/null || echo user)
  BOX_ALIAS="${LUSER}-mac"
fi

# == Phase 1 done ==
sep
if [ "$SETUP_ONLY" = 1 ]; then
  ok "Phase 1 done (--setup-only)."
  say "  Reconnect: ${_B}ssh -O exit $TARGET 2>/dev/null; ssh $TARGET${_0}"
  exit 0
fi

# ===========================================================================
# Phase 2: Reconnect — establish the reverse tunnel automatically
# ===========================================================================
hdr "Phase 2: establishing tunnel"
# Kill existing master connections to the old target
[ -n "$HOST" ] && [ "$HOST" != "$TARGET" ] && ssh -O exit "$HOST" 2>/dev/null || true
ssh -O exit "$TARGET" 2>/dev/null || true
if [ -n "$VIA" ]; then ssh -O exit $VIA 2>/dev/null || true; fi   # $VIA unquoted to word-split; not eval'd

say "  Opening connection as '${_B}$TARGET${_0}' (carries RemoteForward $PORT)..."
ssh -N "$TARGET" >/dev/null 2>&1 &
TUNNEL_PID=$!
trap cleanup EXIT INT TERM HUP   # auto-unmount + drop the tunnel when this script exits

# Poll until the remote port is listening (up to 20s)
READY=0
for i in $(seq 1 10); do
  sleep 2
  # Portable listener check on the box (ss -> netstat -an [GNU/BSD] -> lsof), matching detect.sh /
  # check-tunnel.sh; extracts the port from host:PORT or BSD host.PORT and matches exactly.
  if ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=3 "$TARGET" \
       "{ if command -v ss >/dev/null 2>&1; then ss -tlnH 2>/dev/null | awk '{print \$4}';
          elif command -v netstat >/dev/null 2>&1; then netstat -an 2>/dev/null | awk '/^tcp/ && /LISTEN/{print \$4}';
          elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print \$9}';
          fi; } | sed -E 's/.*[:.]([0-9]+)\$/\1/' | grep -qx '$PORT'" 2>/dev/null; then
    READY=1; break
  fi
done
if [ "$READY" = 1 ]; then
  ok "Tunnel active — remote port $PORT is live"
elif ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
  # The backgrounded `ssh -N` already exited. With ExitOnForwardFailure=yes that means the
  # RemoteForward couldn't bind (port collision on the box) or auth/connect failed. Don't mount over
  # a dead tunnel and surface a misleading "Mount failed" — report the real cause and bail (the EXIT
  # trap runs cleanup; nothing is mounted yet).
  err "Tunnel failed: the SSH connection carrying RemoteForward $PORT exited before the port came up."
  say "    Likely a port collision on the box (another tunnel already holds $PORT) or an ssh auth/connect failure."
  say "    Retry with a different ${_B}--port${_0}, or confirm you can ${_B}ssh $TARGET${_0} non-interactively."
  exit 1
else
  warn "Could not confirm port $PORT on remote (tunnel still up — may still be starting)."
  say "    Proceeding — if the mount fails, reconnect and re-run."
fi

# ===========================================================================
# Phase 3: Pick a project directory ON THIS LAPTOP
# ===========================================================================
hdr "Phase 3: select a laptop project directory"

pick_dir() {
  local result="" def="$PWD"
  printf '  Project dir [%s]: ' "$def" >/dev/tty
  # Read the path from the controlling terminal. Two deliberate choices:
  #  - NO `-i` prefill: a prefilled editable default makes a PASTED absolute path APPEND to it
  #    (e.g. /Users/me + /srv/app → /Users/me/srv/app). The default is shown in the prompt above and
  #    an empty reply falls back to it, so prefilling buys nothing and breaks pasting.
  #  - NO `2>/dev/null` on the readline read: `read -e` echoes typed characters on STDERR, so
  #    redirecting stderr to /dev/null makes your input INVISIBLE as you type.
  # (Plain `read -e`, no `-i`, works the same on bash 3.2 and 4+, so no version branch is needed.)
  if [ -r /dev/tty ]; then
    IFS= read -r -e result </dev/tty || IFS= read -r result </dev/tty
  else
    IFS= read -r result
  fi
  [ -z "$result" ] && result="$def"
  result="${result/#\~/$HOME}"
  printf '%s' "$result"
}

# Use the agent-confirmed dir if it passed one (--project-dir); otherwise prompt interactively.
if [ -n "$PROJ_DIR_ARG" ]; then
  PROJ_DIR="${PROJ_DIR_ARG/#\~/$HOME}"; ok "Project dir (from skill): ${_B}${PROJ_DIR}${_0}"
else
  PROJ_DIR="$(pick_dir)"
fi
PROJ_DIR="${PROJ_DIR%/}"   # strip trailing slash

if [ ! -d "$PROJ_DIR" ]; then
  warn "'$PROJ_DIR' does not exist."
  if ask "  Create it?"; then
    mkdir -p "$PROJ_DIR" && ok "Created $PROJ_DIR"
  else
    err "Aborted."; exit 1
  fi
fi
ok "Selected: ${_B}${PROJ_DIR}${_0}"
PROJ_NAME="$(basename "$PROJ_DIR")"

# ===========================================================================
# Phase 4: Mount on the remote box
# ===========================================================================
hdr "Phase 4: mounting on remote"

# Determine the remote mountpoint:
#  - explicit --remote-mountpoint (e.g. the dir you invoked /remote-harness from) wins;
#  - otherwise default to <remote $HOME>/work/<project-name>.
if [ -n "$REMOTE_MP" ]; then
  REMOTE_MOUNTPOINT="$REMOTE_MP"
else
  REMOTE_MOUNTPOINT=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" \
    "printf '%s/work/%s' \"\$HOME\" $(sq "$PROJ_NAME")" 2>/dev/null || true)
  # /home/<user> is wrong on macOS (/Users); fall back to a generic message rather than a bad path.
  [ -z "$REMOTE_MOUNTPOINT" ] && { warn "could not resolve remote \$HOME; please pass --remote-mountpoint <empty-dir>"; exit 1; }
fi

# Mount, with interactive retry: a recoverable failure (sshfs missing / target not empty) loops
# back instead of exiting, so the tunnel we just established is NOT thrown away.
while :; do
  say "  Remote mountpoint: ${_B}${REMOTE_MOUNTPOINT}${_0}"
  MOUNT_OUT=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "
    mkdir -p $(sq "$REMOTE_MOUNTPOINT")
    rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
    \"\$rh/scripts/mount-project.sh\" \
      --alias $(sq "$BOX_ALIAS") \
      --remote-path $(sq "$PROJ_DIR") \
      --mountpoint $(sq "$REMOTE_MOUNTPOINT")
  " 2>/dev/null || true)
  STATUS=$(printf '%s\n' "$MOUNT_OUT" | awk -F= '/^STATUS=/{print $2; exit}')
  case "$STATUS" in
    mounted|already-mounted)
      ok "Mounted ${PROJ_DIR} → remote:${REMOTE_MOUNTPOINT}"
      MOUNTED=1   # arm auto-unmount in cleanup()
      break
      ;;
    need-sshfs)
      INSTALL_CMD=$(printf '%s\n' "$MOUNT_OUT" | awk -F= '/^INSTALL_CMD=/{print $2; exit}')
      warn "sshfs not installed on the remote box."
      say "  On the remote box, run: ${_B}${INSTALL_CMD:-install sshfs via your package manager}${_0}"
      ask "  Installed sshfs on the box — retry the mount?" && continue
      err "Aborted (sshfs missing)."; exit 1
      ;;
    not-empty)
      warn "Remote mountpoint is not empty: ${REMOTE_MOUNTPOINT}"
      say "  sshfs needs an EMPTY box dir (mounting would hide its existing contents)."
      if [ "$ASSUME_YES" = 1 ] || [ ! -e /dev/tty ]; then
        say "  Re-run with ${_B}--remote-mountpoint <empty-dir>${_0} (or start the agent in a fresh empty dir)."
        exit 1
      fi
      printf '  Enter a different EMPTY box dir (blank to abort): ' >/dev/tty
      newmp=""; IFS= read -r newmp </dev/tty || true
      [ -z "$newmp" ] && { err "Aborted."; exit 1; }
      REMOTE_MOUNTPOINT="${newmp%/}"
      continue
      ;;
    *)
      ERR=$(printf '%s\n' "$MOUNT_OUT" | awk -F= '/^ERROR=/{print $2; exit}')
      err "Mount failed (STATUS=${STATUS:-unknown}): ${ERR:-(no error detail)}"
      say "  Check: is the tunnel active? Is '${BOX_ALIAS}' the right alias on the remote?"
      exit 1
      ;;
  esac
done

# AGENTS.md-only project: only matters for Claude Code (reads CLAUDE.md, not AGENTS.md); codex and
# opencode read AGENTS.md natively, so skip them. Creating CLAUDE.md writes a file INTO your laptop
# repo and is NOT auto-removed on exit — hence opt-in and clearly flagged.
AGENTS_ONLY=$(printf '%s\n' "$MOUNT_OUT" | awk -F= '/^AGENTS_MD_ONLY=/{print $2; exit}')
if [ "$AGENTS_ONLY" = 1 ] && [ "$LAUNCH_BASE" = claude ]; then
  say ""
  say "  Note: this project has AGENTS.md but no CLAUDE.md, and Claude Code reads CLAUDE.md."
  if ask "  Create CLAUDE.md (importing @AGENTS.md) IN YOUR LAPTOP REPO? (not auto-removed)"; then
    ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" \
      "printf '@AGENTS.md\n' > $(sq "$REMOTE_MOUNTPOINT")/CLAUDE.md" 2>/dev/null \
      && ok "CLAUDE.md created in the repo" || warn "could not create CLAUDE.md — do it manually"
  fi
fi

# ===========================================================================
# Phase 5: Launch Claude Code on the remote
# ===========================================================================
# Inject the run-on-laptop rule SCOPED TO THIS SESSION: inject-rule builds box-side, per-session
# artifacts (nothing global, nothing in the mounted repo, so other projects on this box are
# unaffected) and prints how to launch so ONLY this agent reads it — a session flag for claude, or
# an env prefix (CODEX_HOME / OPENCODE_CONFIG) for codex/opencode. For opencode, YOLO's
# permission=allow is folded into that per-session config too.
rh_out=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" \
     "\"\${RH_HOME:-\$HOME/.remote-harness}/scripts/inject-rule.sh\" on $(sq "$LAUNCH_BASE") $(sq "$PROJ_DIR") $(sq "$BOX_ALIAS") $(sq "$REMOTE_MOUNTPOINT") $(sq "$YOLO")" \
     2>/dev/null || printf 'RH_STATUS=ERROR\n')
rh_status=$(printf '%s\n' "$rh_out" | sed -n 's/^RH_STATUS=//p' | head -1)
if [ "$rh_status" = INJECTED ]; then
  RULE_INJECTED=1
  rh_env=$(printf  '%s\n' "$rh_out" | sed -n 's/^RH_LAUNCH_ENV=//p'   | head -1)
  rh_flags=$(printf '%s\n' "$rh_out" | sed -n 's/^RH_LAUNCH_FLAGS=//p' | head -1)
  EFF_LAUNCH="${rh_env:+$rh_env }${EFF_LAUNCH}${rh_flags:+ $rh_flags}"
  ok "Injected session-scoped run-on-laptop rule for ${LAUNCH_BASE} (removed on exit)"
else
  warn "could not inject run-on-laptop rule ($rh_status) — agent may try to build/test on the box"
fi

hdr "Phase 5: launching ${LAUNCH}"
say "  Remote dir: ${_B}${REMOTE_MOUNTPOINT}${_0}"
say "  Your terminal becomes the remote ${LAUNCH} session. Exit ${LAUNCH} to return here."
sep

# Use a LOGIN+INTERACTIVE shell so the remote PATH (e.g. ~/.local/bin from ~/.profile / ~/.zshrc)
# is sourced — `ssh host cmd` alone runs a non-login non-interactive shell and won't find claude.
# ClearAllForwardings=yes: don't re-request the RemoteForward (Phase 2's tunnel already holds it).
ssh -t -o ClearAllForwardings=yes "$TARGET" \
  "cd $(sq "$REMOTE_MOUNTPOINT") && exec \"\${SHELL:-/bin/bash}\" -lic $(sq "$EFF_LAUNCH")"
CLAUDE_EXIT=$?

# ===========================================================================
# Post-session cleanup offer
# ===========================================================================
sep
if [ "$CLAUDE_EXIT" = 0 ]; then
  ok "${LAUNCH} session ended."
else
  warn "${LAUNCH} session ended (exit code $CLAUDE_EXIT)."
fi
# cleanup() (armed via trap) auto-unmounts and drops the tunnel as this script exits.
printf "\n${_B}Done.${_0}\n"
