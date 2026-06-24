#!/usr/bin/env bash
# remote-harness / connect-guesses.sh
# Legacy/opt-in best-effort GUESSES for how the laptop connects to THIS box. The current simple path
# uses suggest-via.sh for a narrower server-side default and asks the user locally. NAT usually hides
# the true public address/port, so these are hints only — the user's own answer is authoritative.
# Prints one candidate `ssh ...` command per line (most-likely first).
set -uo pipefail

U=$(id -un 2>/dev/null || whoami 2>/dev/null || echo user)

# Public egress IP (best-effort; the INBOUND address/port may differ behind NAT/port-forward).
# Prefer curl's own --max-time (no `timeout`, absent on stock macOS); fall back to wget on minimal
# boxes that ship wget but not curl (common on stripped Linux/WSL/container images).
PUB=""
for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
  PUB=$( { curl -fsS --max-time 5 "$url" 2>/dev/null || wget -qO- --timeout=5 "$url" 2>/dev/null; } | tr -d '[:space:]' )
  [ -n "$PUB" ] && break
  PUB=""
done

# LAN IPv4 addresses (useful if the laptop is on the same network): `ip` (Linux) → `ifconfig` (macOS/BSD).
if command -v ip >/dev/null 2>&1; then
  LANS=$(ip -4 -o addr show 2>/dev/null | awk '$2!="lo"{print $4}' | sed 's#/.*##' | grep -vE '^(127\.|169\.254\.)' || true)
else
  LANS=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | sed 's/^addr://' | grep -vE '^(127\.|169\.254\.)' || true)
fi

# Address the inbound SSH connection landed on (may be a NAT gateway / internal IP).
SC=$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $3}')

emitted=""
emit_one(){ case " $emitted " in *" $1 "*) ;; *) emitted="$emitted $1"; printf 'ssh %s@%s\n' "$U" "$1";; esac; }

[ -n "$PUB" ] && emit_one "$PUB"
for ip in $LANS; do emit_one "$ip"; done
[ -n "$SC" ] && emit_one "$SC"

# Always note the caveat on stderr for the agent.
printf 'NOTE: guesses only — NAT/port-forward often hides the real public host/port; confirm with the user.\n' >&2
