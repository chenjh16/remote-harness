#!/usr/bin/env bash
# remote-harness / check-tunnel.sh
# Verify the reverse tunnel: is the loopback listener up, and does `ssh <alias>` reach
# the laptop? Read-only. Prints KEY=VALUE lines.
set -uo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }

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

# Is something listening on that loopback port?
if [ -n "$PORT" ] && { ss -tlnH 2>/dev/null || true; } \
     | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | grep -qx "$PORT"; then
  emit LISTENER up
else
  emit LISTENER down
fi

# Try an actual login through the tunnel.
err="$(mktemp)"
out=$(timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "$ALIAS" \
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
