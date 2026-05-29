#!/usr/bin/env bash
# remote-harness / setup-tunnel.sh
# Configure THIS machine's ~/.ssh/config so that `ssh <alias>` reaches the laptop
# over the reverse tunnel that the laptop opens with `RemoteForward <port> 127.0.0.1:22`.
# Idempotent (re-runnable). Backs up ~/.ssh/config. Generates an ed25519 key if asked.
# Prints KEY=VALUE lines on stdout; human notes on stderr.
set -euo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }
note() { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

ALIAS="" PORT="" LUSER="" IDENTITY="" GEN_KEY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --alias)    ALIAS="$2"; shift 2;;
    --port)     PORT="$2"; shift 2;;
    --user)     LUSER="$2"; shift 2;;
    --identity) IDENTITY="$2"; shift 2;;
    --gen-key)  GEN_KEY=1; shift;;
    *) die "unknown argument: $1";;
  esac
done
[ -n "$ALIAS" ] && [ -n "$PORT" ] && [ -n "$LUSER" ] \
  || die "usage: setup-tunnel.sh --alias NAME --port PORT --user LAPTOP_USER [--identity KEYFILE] [--gen-key]"
printf '%s' "$PORT" | grep -qE '^[0-9]+$' || die "port must be numeric: $PORT"
printf '%s' "$ALIAS" | grep -qE '^[A-Za-z0-9._-]+$' || die "alias has unsafe characters: $ALIAS"

mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh" 2>/dev/null || true
CFG="$HOME/.ssh/config"; touch "$CFG"; chmod 600 "$CFG" 2>/dev/null || true
KH="$HOME/.ssh/known_hosts_${ALIAS}"

# --- pick / create an identity key -----------------------------------------
if [ -z "$IDENTITY" ]; then
  for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do
    [ -f "$k" ] && { IDENTITY="$k"; break; }
  done
fi
if [ -z "$IDENTITY" ] && [ "$GEN_KEY" = 1 ]; then
  IDENTITY="$HOME/.ssh/id_ed25519"
  note "No SSH key found; generating $IDENTITY (no passphrase)."
  ssh-keygen -t ed25519 -N "" -f "$IDENTITY" -C "remote-harness@$(hostname 2>/dev/null || echo host)" >/dev/null
fi

# --- ephemeral-floor sanity check ------------------------------------------
low=$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null); low=${low:-32768}
if [ "$PORT" -ge "$low" ]; then
  note "WARNING: port $PORT is within the ephemeral range (>= $low); it may occasionally"
  note "         collide with an outbound connection. A fixed port below $low is safer."
fi

# --- write an idempotent managed block -------------------------------------
BEGIN="# >>> remote-harness:${ALIAS} >>> (managed; edits here are overwritten)"
END="# <<< remote-harness:${ALIAS} <<<"
cp "$CFG" "$CFG.rh-bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)" 2>/dev/null || true

tmp="$(mktemp)"
awk -v b="$BEGIN" -v e="$END" '
  index($0,"# >>> remote-harness:")==1 && index($0, b)==1 {skip=1}
  skip==0 {print}
  $0==e {skip=0}
' "$CFG" > "$tmp"

{
  cat "$tmp"
  printf '%s\n' "$BEGIN"
  printf '# %s reaches your laptop via the reverse tunnel (laptop adds: RemoteForward %s 127.0.0.1:22)\n' "$ALIAS" "$PORT"
  printf 'Host %s\n' "$ALIAS"
  printf '    HostName 127.0.0.1\n'
  printf '    Port %s\n' "$PORT"
  printf '    User %s\n' "$LUSER"
  [ -n "$IDENTITY" ] && printf '    IdentityFile %s\n' "$IDENTITY"
  printf '    UserKnownHostsFile %s\n' "$KH"
  printf '    StrictHostKeyChecking accept-new\n'
  printf '    ServerAliveInterval 30\n'
  printf '    ServerAliveCountMax 3\n'
  # Multiplex: keep one warm connection so repeated ssh / sshfs to the laptop are snappy.
  printf '    ControlMaster auto\n'
  printf '    ControlPath ~/.ssh/cm-%%r@%%h:%%p\n'
  printf '    ControlPersist 5m\n'
  printf '%s\n' "$END"
} > "$CFG"
rm -f "$tmp"
chmod 600 "$CFG" 2>/dev/null || true

emit STATUS configured
emit ALIAS "$ALIAS"
emit PORT "$PORT"
emit IDENTITY "${IDENTITY:-}"
emit KNOWN_HOSTS "$KH"
emit REMOTEFORWARD_LINE "RemoteForward $PORT 127.0.0.1:22"
if [ -n "$IDENTITY" ] && [ -f "$IDENTITY.pub" ]; then
  emit PUBKEY "$(cat "$IDENTITY.pub")"
else
  emit PUBKEY ""
  note "No identity public key available; the laptop must already trust this box's key,"
  note "or re-run with --gen-key to create one."
fi
note "Wrote Host '$ALIAS' to $CFG (managed block)."
