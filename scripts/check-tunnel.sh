#!/usr/bin/env bash
# remote-harness / check-tunnel.sh
# Verify the reverse tunnel: is the loopback listener up, and does `ssh <alias>` reach
# the laptop? Read-only. Prints KEY=VALUE lines.
set -uo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }

# Listening TCP ports, across environments: ss → netstat (GNU/BSD) → lsof.
listening_ports() {
  { if   command -v ss      >/dev/null 2>&1; then ss -tlnH 2>/dev/null | awk '{print $4}'
    elif command -v netstat >/dev/null 2>&1; then netstat -an 2>/dev/null | awk '/^tcp/ && /LISTEN/{print $4}'
    elif command -v lsof    >/dev/null 2>&1; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}'
    fi; } | sed -E 's/.*[:.]([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un
}

ALIAS="" PORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --alias) ALIAS="$2"; shift 2;;
    --port)  PORT="$2"; shift 2;;
    *) shift;;
  esac
done
[ -n "$ALIAS" ] || { printf 'usage: check-tunnel.sh --alias NAME [--port PORT]\n' >&2; exit 2; }

# Derive the port from ssh -G if not supplied.
if [ -z "$PORT" ]; then
  PORT=$(ssh -G "$ALIAS" 2>/dev/null | awk '$1=="port"{print $2}')
fi
emit ALIAS "$ALIAS"
emit PORT "${PORT:-}"

# Is something listening on that loopback port? (best-effort diagnostic; the login test below is
# the authoritative check, so a tool-less box that reports "down" here still proceeds.)
if [ -n "$PORT" ] && listening_ports | grep -qx "$PORT"; then
  emit LISTENER up
else
  emit LISTENER down
fi

# Try an actual login through the tunnel. Use `timeout` only if present (absent on stock macOS);
# ssh's own ConnectTimeout + ServerAlive bound the call either way.
err="$(mktemp)"
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"
out=$($TO ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$ALIAS" \
        'printf "RH_OK %s %s" "$(hostname 2>/dev/null)" "$(id -un 2>/dev/null)"' 2>"$err") || true
if printf '%s' "$out" | grep -q '^RH_OK'; then
  emit SSH up
  emit LAPTOP_HOSTNAME "$(printf '%s' "$out" | awk '{print $2}')"
  emit LAPTOP_USER "$(printf '%s' "$out" | awk '{print $3}')"
else
  emit SSH down
  emit ERROR "$(tr '\n' ' ' < "$err" 2>/dev/null | sed 's/  */ /g' | cut -c1-300)"
fi
rm -f "$err" 2>/dev/null || true
