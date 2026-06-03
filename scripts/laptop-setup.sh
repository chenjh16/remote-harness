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
#   (
#     d=$(mktemp -d "${TMPDIR:-/tmp}/rh.XXXXXX") || exit
#     trap 'rm -rf "$d"' EXIT
#     ssh -o ClearAllForwardings=yes <CONNECT> 'cat ~/.remote-harness/scripts/_common.sh'      >"$d/_common.sh" &&
#     ssh -o ClearAllForwardings=yes <CONNECT> 'cat ~/.remote-harness/scripts/laptop-setup.sh' >"$d/laptop-setup.sh" &&
#     bash "$d/laptop-setup.sh" --host <HOST> --port <PORT> --via '<CONNECT>' --box-alias <ALIAS>
#   )
#
# Flags:
#   --host <alias|ip>     ssh entry used to reach the box; a dedicated harness alias is managed
#   --port <PORT>         RemoteForward port on the remote (required)
#   --via <ssh-args>      exact ssh args to reach the box (e.g. "-p 2222 user@1.2.3.4")
#   --box-alias <name>    alias the BOX uses to reach back to this laptop (default: <user>-mac)
#   --pubkey <key>        box public key to authorize (fetched via --via if omitted)
#   --box-user <user>     remote box username (for mount path and alias naming)
#   --remote-mountpoint <d>  exact box dir to mount the project at (must be empty;
#                            default: <remote $HOME>/work/<project-name>)
#   --project-dir <d>     laptop project dir to mount (validated; prompts again if invalid)
#   --launch <cmd>        coding-agent CLI to start on the remote (default: claude;
#                         Codex passes 'codex', opencode passes 'opencode')
#   --yolo                bypass approvals on the launched agent — claude/codex get their
#                         bypass flag; opencode gets a temporary permission=allow config (restored)
#   --setup-only          stop after Phase 1 — skip reconnect / dir-pick / mount / launch
#   --yes                 non-interactive (skip all confirm prompts)
set -uo pipefail

need_arg() {
  if [ -z "${2+x}" ] || [ -z "$2" ]; then
    printf 'missing value for %s\n' "$1" >&2
    exit 2
  fi
}

# ---- argument parsing -----------------------------------------------------
HOST="" PORT="" PUBKEY="" VIA="" BOX_ALIAS="" ASSUME_YES=0 SETUP_ONLY=0
BOX_USER="" REMOTE_MP="" LAUNCH="claude" PROJ_DIR_ARG=""
YOLO=0; EFF_LAUNCH=""; LAUNCH_BASE="claude"
while [ $# -gt 0 ]; do
  case "$1" in
    --host)          need_arg "$1" "${2-}"; HOST="$2";           shift 2;;
    --port)          need_arg "$1" "${2-}"; PORT="$2";           shift 2;;
    --pubkey)        need_arg "$1" "${2-}"; PUBKEY="$2";         shift 2;;
    --via)           need_arg "$1" "${2-}"; VIA="$2";            shift 2;;
    --launch)        need_arg "$1" "${2-}"; LAUNCH="$2";         shift 2;;   # CLI to start on the remote (claude/codex/opencode)
    --yolo)          YOLO=1;              shift;;     # bypass approvals on the launched agent
    --box-alias)     need_arg "$1" "${2-}"; BOX_ALIAS="$2";      shift 2;;
    --box-user)      need_arg "$1" "${2-}"; BOX_USER="$2";       shift 2;;
    --remote-mountpoint) need_arg "$1" "${2-}"; REMOTE_MP="$2";  shift 2;;   # exact box dir to mount at (e.g. your invoking cwd)
    --project-dir)   need_arg "$1" "${2-}"; PROJ_DIR_ARG="$2";   shift 2;;   # laptop project dir (skip the interactive prompt)
    --setup-only)    SETUP_ONLY=1;        shift;;
    --yes|-y)        ASSUME_YES=1;        shift;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
  esac
done
[ -n "$PORT" ] || { printf 'need --port\n' >&2; exit 2; }
printf '%s' "$PORT" | grep -qE '^[0-9]+$' || { printf 'port must be numeric: %s\n' "$PORT" >&2; exit 2; }
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { printf 'port out of range: %s\n' "$PORT" >&2; exit 2; }

# ---- shared helpers (colors, say/ok/warn/err/hdr/ask, sq, OS vars, parse_via, ssh-config) -------
# laptop-setup.sh is fetched to the laptop and run STANDALONE (the laptop usually has no install),
# so the skill's one-command fetches _common.sh next to this file and we source it by path.
RH_COMMON="${RH_COMMON:-$(dirname "$0")/_common.sh}"
if [ -f "$RH_COMMON" ]; then
  # shellcheck source=./_common.sh
  . "$RH_COMMON"
else printf 'error: missing _common.sh next to %s — re-copy the full command\n' "$0" >&2; exit 2; fi

# ---- auto-cleanup on exit/disconnect ---------------------------------------
TUNNEL_PID=""; MOUNTED=0; CLEANED=0; RULE_INJECTED=0

# Path to the per-(box,port) pid file recording WHO owns the reverse tunnel (the live `ssh -N` pid),
# so the LAST session out can drop it even if it didn't create it — same-user multi-project, where a
# second session reuses the tunnel. Keyed by TARGET+PORT (evaluated at call time, after they're set).
tunnel_state_path() {
  printf '%s/.remote-harness/.tunnel-%s.pid' "$HOME" \
    "$(printf '%s-%s' "${TARGET:-}" "${PORT:-}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
}
# True if the box STILL has another sshfs mount riding this reverse tunnel (a different session's
# '<BOX_ALIAS>:…' mount remains after we've unmounted ours). Best-effort: false on error, and on a
# macOS/FUSE-T box (its mount source isn't '<alias>:path', so it can't be detected — the tunnel is
# then dropped as before).
tunnel_still_needed() {
  [ -n "${BOX_ALIAS:-}" ] && [ -n "${TARGET:-}" ] || return 1
  _cnt="$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" \
    "mount 2>/dev/null | grep -F -- $(sq "$BOX_ALIAS:") 2>/dev/null | grep -c -i fuse" 2>/dev/null)"
  case "${_cnt:-0}" in *[!0-9]*) _cnt=0;; esac
  [ "${_cnt:-0}" -gt 0 ]
}

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
  # Drop the reverse tunnel ONLY when no other session still rides it. Whoever exits LAST tears it
  # down — via the creator's pid file (the live `ssh -N` pid persists as an orphan after an early
  # creator exit, so killing that pid still closes the tunnel) — so an early exit by the creator no
  # longer strands another project's mount. Runs for reusers too (their own TUNNEL_PID is empty).
  if [ "$MOUNTED" = 1 ] || [ -n "$TUNNEL_PID" ]; then
    if tunnel_still_needed; then
      warn "another session's mount still uses this reverse tunnel — leaving it up"
    else
      _sp="$(tunnel_state_path)"; _pid="${TUNNEL_PID:-}"
      [ -z "$_pid" ] && [ -f "$_sp" ] && _pid="$(cat "$_sp" 2>/dev/null)"
      [ -n "$_pid" ] && kill "$_pid" 2>/dev/null || true
      rm -f "$_sp" 2>/dev/null || true
    fi
  fi
}

# OS vars (OS/PLAT/IS_WSL) come from _common.sh.
printf "\n${_B}remote-harness${_0} laptop setup  ${_C}port=%s${_0}  platform=%s\n\n" "$PORT" "$PLAT"

# Resolve YOLO into the effective launch command per agent.
case "$LAUNCH" in
  claude|codex|opencode) ;;
  *) printf 'unsupported --launch %s (expected claude|codex|opencode)\n' "$LAUNCH" >&2; exit 2;;
esac
EFF_LAUNCH="$LAUNCH"
LAUNCH_BASE="$LAUNCH"
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
[ -z "${V_UNSUPPORTED_SSH_OPTIONS:-}" ] || {
  printf 'unsupported ssh option(s) in --via:%s\n' "$V_UNSUPPORTED_SSH_OPTIONS" >&2
  printf 'Put complex ssh options in ~/.ssh/config as a Host alias, then pass that alias.\n' >&2
  exit 2
}
[ -z "$V_HOST" ] && [ -n "$HOST" ] && V_HOST="$HOST"
[ -z "$BOX_USER" ] && BOX_USER="$V_USER"
[ -z "$V_HOST" ] || safe_ssh_token "$V_HOST" || { printf 'unsafe ssh host in --via: %s\n' "$V_HOST" >&2; exit 2; }
[ -z "$HOST" ] || safe_ssh_token "$HOST" || { printf 'unsafe --host: %s\n' "$HOST" >&2; exit 2; }
[ -z "$BOX_ALIAS" ] || safe_ssh_token "$BOX_ALIAS" || { printf 'unsafe --box-alias: %s\n' "$BOX_ALIAS" >&2; exit 2; }
[ -z "$BOX_USER" ] || safe_ssh_token "$BOX_USER" || { printf 'unsafe --box-user: %s\n' "$BOX_USER" >&2; exit 2; }

# -- obtain the box's public key --
if [ -z "$PUBKEY" ]; then
  KCMD='cat ~/.remote-harness/.tunnel-pubkey 2>/dev/null || cat ~/.ssh/id_ed25519.pub 2>/dev/null'
  if [ -n "$VIA" ]; then
    # $VIA is intentionally unquoted so it word-splits into ssh args; NOT eval'd (avoids running
    # shell metacharacters in a mistyped/crafted connect string locally).
    PUBKEY="$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 $VIA "$KCMD" 2>/dev/null || true)"
  elif [ -n "$HOST" ]; then
    PUBKEY="$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$KCMD" 2>/dev/null || true)"
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
      if command -v apt-get >/dev/null 2>&1; then
        ask "  sshd not found. Install via apt-get?" && sudo apt-get install -y openssh-server
      elif command -v dnf >/dev/null 2>&1; then
        ask "  sshd not found. Install via dnf?" && sudo dnf install -y openssh-server
      elif command -v pacman >/dev/null 2>&1; then
        ask "  sshd not found. Install via pacman?" && sudo pacman -S --noconfirm openssh
      elif command -v apk >/dev/null 2>&1; then
        ask "  sshd not found. Install via apk?" && sudo apk add openssh
      else
        warn "sshd not found and no supported package manager was detected; install OpenSSH server manually."
      fi
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

legacy_host_has_rh_forward() {
  local _host="$1"
  [ -f "$CFG" ] || return 1
  awk -v host="$_host" '
    function H(s){return s~/^[ \t]*[Hh][Oo][Ss][Tt][ \t]/}
    H($0){hit=0;n=split($0,a,/[ \t]+/);for(i=2;i<=n;i++){if(a[i]=="#")break;if(a[i]==host)hit=1}}
    hit&&$0~/^[ \t]*RemoteForward[ \t]+[0-9]+[ \t]+127\.0\.0\.1:22[ \t]*$/ {found=1}
    END{exit !found}
  ' "$CFG"
}
remove_legacy_host_forward() {
  local _host="$1" _tmp
  _tmp="$(mktemp)"
  awk -v host="$_host" '
    function H(s){return s~/^[ \t]*[Hh][Oo][Ss][Tt][ \t]/}
    H($0){hit=0;n=split($0,a,/[ \t]+/);for(i=2;i<=n;i++){if(a[i]=="#")break;if(a[i]==host)hit=1};print;next}
    hit&&$0~/^[ \t]*RemoteForward[ \t]+[0-9]+[ \t]+127\.0\.0\.1:22[ \t]*$/ {next}
    hit&&$0~/^[ \t]*(ServerAliveInterval|ServerAliveCountMax|ExitOnForwardFailure|TCPKeepAlive)([ \t]|$)/ {next}
    {print}
  ' "$CFG" > "$_tmp" && mv "$_tmp" "$CFG"
}
load_effective_ssh_alias() {
  local _alias="$1" _cfg _identity
  _cfg="$(ssh -G "$_alias" 2>/dev/null || true)"
  [ -n "$_cfg" ] || return 1
  V_HOST=$(printf '%s\n' "$_cfg" | awk 'tolower($1)=="hostname"{print $2; exit}')
  V_PORT=$(printf '%s\n' "$_cfg" | awk 'tolower($1)=="port"{print $2; exit}')
  V_USER=$(printf '%s\n' "$_cfg" | awk 'tolower($1)=="user"{print $2; exit}')
  V_PROXYJUMP=$(printf '%s\n' "$_cfg" | awk 'tolower($1)=="proxyjump" && $2!="none"{print $2; exit}')
  V_IDENTITY=""
  while IFS= read -r _identity; do
    case "$_identity" in ~/*) _identity="$HOME/${_identity#~/}";; esac
    [ -f "$_identity" ] && { V_IDENTITY="$_identity"; break; }
  done <<EOF
$(printf '%s\n' "$_cfg" | awk 'tolower($1)=="identityfile"{print $2}')
EOF
}
# The --via connection is the GROUND TRUTH for how to reach the box. Use a DEDICATED managed alias
# for the harness connection even when --via is a normal `Host <alias>` alias; otherwise ordinary
# `ssh <alias>` inherits RemoteForward and fails while a harness tunnel already owns the port.
cp "$CFG" "$CFG.rh-bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)" 2>/dev/null || true
RAW_CONN=0; { [ -n "$V_PORT" ] || [ -n "$V_USER" ] || [ -n "$V_IDENTITY" ] || [ -n "$V_PROXYJUMP" ]; } && RAW_CONN=1
if [ "$RAW_CONN" = 0 ] && [ -n "$HOST" ] && block_exists "$HOST"; then
  load_effective_ssh_alias "$HOST" || warn "ssh config: could not resolve Host '$HOST' with ssh -G; using it as HostName"
  if legacy_host_has_rh_forward "$HOST"; then
    remove_legacy_host_forward "$HOST" \
      && ok "ssh config: removed legacy remote-harness RemoteForward from existing 'Host $HOST'" \
      || warn "ssh config: could not remove legacy RemoteForward from 'Host $HOST'"
  fi
fi
[ -z "${V_HOST:-}" ] || safe_ssh_token "$V_HOST" || { printf 'unsafe resolved ssh HostName: %s\n' "$V_HOST" >&2; exit 2; }
[ -z "${V_USER:-}" ] || safe_ssh_token "$V_USER" || { printf 'unsafe resolved ssh User: %s\n' "$V_USER" >&2; exit 2; }
[ -z "${V_PROXYJUMP:-}" ] || safe_ssh_token "$V_PROXYJUMP" || { printf 'unsafe resolved ssh ProxyJump: %s\n' "$V_PROXYJUMP" >&2; exit 2; }
TARGET="${HOST:-${BOX_USER:-${V_USER:-box}}}-remote-harness"
write_target_forward() {
  local _port="$1" _rf_line _tmp
  _rf_line="    RemoteForward $_port 127.0.0.1:22"
  if [ "$REUSE" = 1 ]; then
    _tmp="$(mktemp)"
    # Insert RemoteForward + tunnel keepalives into the user's existing alias block, de-duping our own
    # managed lines first so re-runs stay idempotent (use 'hit' not 'in' — reserved in BSD awk). The
    # keepalives mirror the managed-alias branch so a reused alias detects a half-open NAT tunnel and
    # fails loudly on a port collision instead of leaving a live-but-no-forward connection.
    if awk -v host="$TARGET" -v rf="$_rf_line" \
        -v o1="    ServerAliveInterval 30" -v o2="    ServerAliveCountMax 3" \
        -v o3="    ExitOnForwardFailure yes" -v o4="    TCPKeepAlive yes" '
      function H(s){return s~/^[ \t]*[Hh][Oo][Ss][Tt][ \t]/}
      BEGIN{hit=0}
      {if(H($0)){hit=0;n=split($0,a,/[ \t]+/);for(i=1;i<=n;i++){if(a[i]=="#")break;if(i>1&&a[i]==host)hit=1}
       print;if(hit){print rf;print o1;print o2;print o3;print o4}next}
       if(hit&&$0~/^[ \t]*RemoteForward[ \t]+[0-9]+[ \t]+127\.0\.0\.1:22[ \t]*$/)next
       if(hit&&$0~/^[ \t]*(ServerAliveInterval|ServerAliveCountMax|ExitOnForwardFailure|TCPKeepAlive)([ \t]|$)/)next
       print}' "$CFG" > "$_tmp" && mv "$_tmp" "$CFG"; then
      ok "ssh config: set RemoteForward $_port + keepalives inside existing 'Host $TARGET'"
    else
      warn "ssh config: awk edit failed — add '$_rf_line' under 'Host $TARGET' manually"; rm -f "$_tmp"
      return 1
    fi
  else
    # Create-or-replace a managed alias carrying the exact --via identity + RemoteForward (idempotent).
    # Keepalives so a half-open tunnel (NAT idle / laptop sleep) is detected; ExitOnForwardFailure so a
    # port-collision fails loudly instead of leaving a live-but-no-forward connection that polls as "up".
    if write_managed_alias "$TARGET" "$_rf_line" \
        "    ServerAliveInterval 30" "    ServerAliveCountMax 3" \
        "    ExitOnForwardFailure yes" "    TCPKeepAlive yes"; then
      ok "ssh config: wrote managed 'Host $TARGET' (HostName ${V_HOST:-?}, port ${V_PORT:-22}, user ${V_USER:-<login default>}) + RemoteForward $_port"
    else
      err "ssh config: could not write managed Host '$TARGET'"
      return 1
    fi
  fi
}
write_target_forward "$PORT" || exit 2
if [ "$REUSE" != 1 ]; then
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

trap cleanup EXIT INT TERM HUP   # auto-unmount + drop the tunnel when this script exits

remote_port_listening() {
  local _port="$1"
  # Portable listener check on the box (ss -> netstat -an [GNU/BSD] -> lsof), matching detect.sh /
  # check-tunnel.sh; extracts the port from host:PORT or BSD host.PORT and matches exactly.
  ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=3 "$TARGET" \
    "{ if command -v ss >/dev/null 2>&1; then ss -tlnH 2>/dev/null | awk '{print \$4}';
       elif command -v netstat >/dev/null 2>&1; then netstat -an 2>/dev/null | awk '/^tcp/ && /LISTEN/{print \$4}';
       elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print \$9}';
       fi; } | sed -E 's/.*[:.]([0-9]+)\$/\1/' | grep -qx $(sq "$_port")" 2>/dev/null
}
tunnel_alias_up() {
  local _port="$1" out laptop_host laptop_user local_host local_user
  out=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" "
    rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
    if [ -x \"\$rh/scripts/check-tunnel.sh\" ]; then
      \"\$rh/scripts/check-tunnel.sh\" --alias $(sq "$BOX_ALIAS") --port $(sq "$_port")
    else
      ssh -o BatchMode=yes -o ConnectTimeout=5 $(sq "$BOX_ALIAS") 'printf \"RH_OK %s %s\" \"\$(hostname 2>/dev/null)\" \"\$(id -un 2>/dev/null)\"'
    fi
  " 2>/dev/null || true)
  if printf '%s\n' "$out" | grep -q '^SSH=up'; then
    laptop_host=$(printf '%s\n' "$out" | awk -F= '/^LAPTOP_HOSTNAME=/{print $2; exit}')
    laptop_user=$(printf '%s\n' "$out" | awk -F= '/^LAPTOP_USER=/{print $2; exit}')
  elif printf '%s' "$out" | grep -q '^RH_OK'; then
    laptop_host=$(printf '%s' "$out" | awk '{print $2}')
    laptop_user=$(printf '%s' "$out" | awk '{print $3}')
  else
    return 1
  fi
  local_host=$(hostname 2>/dev/null || true)
  local_user=$(id -un 2>/dev/null || true)
  [ -z "$laptop_host" ] || [ -z "$local_host" ] || [ "$laptop_host" = "$local_host" ] || return 1
  [ -z "$laptop_user" ] || [ -z "$local_user" ] || [ "$laptop_user" = "$local_user" ] || return 1
  return 0
}

find_next_remote_port() {
  local _start="$1" _port _end
  _port="$_start"
  _end=$((_start + 200))
  [ "$_end" -le 65535 ] || _end=65535
  while [ "$_port" -le "$_end" ]; do
    if ! remote_port_listening "$_port"; then
      printf '%s' "$_port"
      return 0
    fi
    _port=$((_port + 1))
  done
  return 1
}

remote_box_alias_info() {
  ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" "
    cfg=\$(ssh -G $(sq "$BOX_ALIAS") 2>/dev/null || true)
    user=\$(printf '%s\n' \"\$cfg\" | awk 'tolower(\$1)==\"user\"{print \$2; exit}')
    identity=\$(printf '%s\n' \"\$cfg\" | awk 'tolower(\$1)==\"identityfile\"{print \$2; exit}')
    case \"\$identity\" in \"~/\"*) identity=\"\$HOME/\${identity#~/}\";; esac
    [ -f \"\$identity\" ] || identity=\"\"
    printf 'USER=%s\nIDENTITY=%s\n' \"\$user\" \"\$identity\"
  " 2>/dev/null || true
}

update_box_alias_port() {
  local _port="$1" info laptop_user identity identity_arg="" out
  info=$(remote_box_alias_info)
  laptop_user=$(printf '%s\n' "$info" | awk -F= '/^USER=/{print $2; exit}')
  identity=$(printf '%s\n' "$info" | awk -F= '/^IDENTITY=/{print $2; exit}')
  [ -n "$laptop_user" ] || laptop_user=$(id -un 2>/dev/null || printf user)
  [ -n "$identity" ] && identity_arg=" --identity $(sq "$identity")"
  out=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "
    rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
    [ -x \"\$rh/scripts/setup-tunnel.sh\" ] || { printf 'ERROR=missing setup-tunnel.sh\n'; exit 2; }
    \"\$rh/scripts/setup-tunnel.sh\" --alias $(sq "$BOX_ALIAS") --port $(sq "$_port") --user $(sq "$laptop_user")$identity_arg
  " 2>&1) || {
    err "Could not update remote alias '$BOX_ALIAS' to port $_port."
    printf '%s\n' "$out" >&2
    return 1
  }
  ok "box alias: updated '$BOX_ALIAS' to remote port $_port"
}

switch_tunnel_port() {
  local old_port="$PORT" new_port
  new_port=$(find_next_remote_port "$((PORT + 1))") || {
    err "Remote port $PORT is occupied, and no free port was found in the next 200 ports."
    say "    Close the stale/conflicting SSH session, or rerun remote-harness and choose a known free port."
    return 1
  }
  warn "Remote port $old_port is already listening, but '$BOX_ALIAS' does not reach this laptop."
  say "    Switching this setup to remote port ${_B}$new_port${_0} and continuing."
  update_box_alias_port "$new_port" || return 1
  PORT="$new_port"
  write_target_forward "$PORT" || return 1
  chmod 600 "$CFG" 2>/dev/null || true
}

while :; do
  if tunnel_alias_up "$PORT"; then
    ok "Reusing existing reverse tunnel — $BOX_ALIAS already reaches this laptop on remote port $PORT"
    say "    This script did not create that tunnel, so it will leave the tunnel itself running on exit."
    break
  fi
  if remote_port_listening "$PORT"; then
    switch_tunnel_port || exit 1
    continue
  fi

  say "  Opening connection as '${_B}$TARGET${_0}' (carries RemoteForward $PORT)..."
  ssh -N "$TARGET" >/dev/null 2>&1 &
  TUNNEL_PID=$!

  # Poll until the remote port is listening (up to 20s)
  READY=0
  for _ in $(seq 1 10); do
    sleep 2
    if remote_port_listening "$PORT"; then READY=1; break; fi
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
  done
  if [ "$READY" = 1 ]; then
    ok "Tunnel active — remote port $PORT is live"
    break
  elif ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    # The backgrounded `ssh -N` already exited. With ExitOnForwardFailure=yes that means the
    # RemoteForward couldn't bind (port collision on the box) or auth/connect failed. Don't mount over
    # a dead tunnel and surface a misleading "Mount failed" — report the real cause and bail (the EXIT
    # trap runs cleanup; nothing is mounted yet).
    TUNNEL_PID=""
    if remote_port_listening "$PORT"; then
      switch_tunnel_port || exit 1
      continue
    fi
    err "Tunnel failed: the SSH connection carrying RemoteForward $PORT exited before the port came up."
    say "    Likely an ssh auth/connect failure. Confirm you can ${_B}ssh $TARGET${_0} non-interactively."
    exit 1
  else
    warn "Could not confirm port $PORT on remote (tunnel still up — may still be starting)."
    say "    Proceeding — if the mount fails, reconnect and re-run."
    break
  fi
done

# Record who owns the tunnel (the live `ssh -N` pid) so the LAST session out — which may be a
# different, reusing session — can drop it cleanly. Only the creator writes it; reusers (which broke
# out via tunnel_alias_up) have an empty TUNNEL_PID and rely on the creator's file.
if [ -n "$TUNNEL_PID" ]; then
  mkdir -p "$HOME/.remote-harness" 2>/dev/null || true
  printf '%s\n' "$TUNNEL_PID" > "$(tunnel_state_path)" 2>/dev/null || true
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

choose_project_dir() {
  local candidate="${1:-}" from_arg="${2:-0}" newdir=""
  [ -n "$candidate" ] || candidate="$(pick_dir)"
  while :; do
    candidate="${candidate/#\~/$HOME}"
    candidate="${candidate%/}"
    if [ -d "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
    if [ "$from_arg" = 1 ]; then
      warn "Project dir from skill is not a directory: $candidate" >&2
      from_arg=0
    else
      warn "Project dir is not a directory: $candidate" >&2
    fi
    if [ ! -e "$candidate" ]; then
      if ask "  Create it?"; then
        if mkdir -p "$candidate" 2>/dev/null && [ -d "$candidate" ]; then
          ok "Created $candidate" >&2
          printf '%s' "$candidate"
          return 0
        fi
        warn "Could not create $candidate" >&2
      fi
    else
      warn "Path exists but is not a directory." >&2
    fi
    if [ "$ASSUME_YES" = 1 ] || [ ! -e /dev/tty ]; then
      err "No valid project directory selected."
      exit 1
    fi
    printf '  Enter a laptop project dir (blank to abort): ' >/dev/tty
    newdir=""
    IFS= read -r newdir </dev/tty || true
    [ -n "$newdir" ] || { err "Aborted."; exit 1; }
    candidate="$newdir"
  done
}

# Use the agent-confirmed dir if it passed one (--project-dir); otherwise prompt interactively.
if [ -n "$PROJ_DIR_ARG" ]; then
  if ! PROJ_DIR="$(choose_project_dir "$PROJ_DIR_ARG" 1)"; then exit 1; fi
  ok "Project dir (from skill): ${_B}${PROJ_DIR}${_0}"
else
  if ! PROJ_DIR="$(choose_project_dir "" 0)"; then exit 1; fi
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
# an env/config prefix (Codex developer_instructions / OPENCODE_CONFIG) for codex/opencode. For opencode, YOLO's
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
