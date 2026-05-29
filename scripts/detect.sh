#!/usr/bin/env bash
# remote-harness / detect.sh
# Read-only environment probe. Makes NO changes. Prints KEY=VALUE lines on stdout
# for the agent to parse, plus a human summary on stderr.
set -uo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }
note() { printf '%s\n' "$*" >&2; }

# Sorted, unique list of TCP ports currently being listened on (any address).
listening_ports() {
  { ss -tlnH 2>/dev/null || netstat -tlnH 2>/dev/null; } \
    | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un
}
port_in_use() { listening_ports | grep -qx "$1"; }

note "== remote-harness: probing environment =="

# --- Which side are we on? -------------------------------------------------
if [ -n "${SSH_CONNECTION:-}" ]; then
  emit ON_REMOTE 1
  emit CLIENT_IP "$(printf '%s' "$SSH_CONNECTION" | awk '{print $1}')"
  note "We are the REMOTE box (reached via SSH from ${SSH_CONNECTION%% *})."
else
  emit ON_REMOTE 0
  emit CLIENT_IP ""
  note "No SSH_CONNECTION: this shell was not opened over SSH. remote-harness is"
  note "designed to run on the remote dev box; continue only if you know why."
fi

# --- Host facts ------------------------------------------------------------
emit HOSTNAME "$(hostname 2>/dev/null || echo unknown)"
emit REMOTE_USER "$(id -un 2>/dev/null || whoami 2>/dev/null || echo unknown)"
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then emit IS_WSL 1; else emit IS_WSL 0; fi

# --- Ephemeral port floor (pick a fixed tunnel port BELOW this) ------------
low=$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)
low=${low:-32768}
emit EPHEMERAL_LOW "$low"

# --- Suggest a free, distinctive port below the ephemeral floor ------------
suggested=""
for p in 29222 27022 22022 31822 23922 25022 21022; do
  if [ "$p" -lt "$low" ] && ! port_in_use "$p"; then suggested="$p"; break; fi
done
emit SUGGESTED_PORT "$suggested"

# --- Existing loopback listeners (possible prior tunnels) ------------------
existing=$({ ss -tlnH 2>/dev/null || true; } \
  | awk '$4 ~ /^(127\.0\.0\.1|\[::1\]):/ {print $4}' \
  | sed -E 's/.*:([0-9]+)$/\1/' | sort -un \
  | awk '$1>1024 && $1<32768' | paste -sd, -)
emit EXISTING_LOOPBACK_PORTS "${existing:-}"

# --- SSH keys on this box (used to authenticate BACK to the laptop) --------
keys=""; default_id=""
for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do
  if [ -f "$k" ]; then keys="$keys${keys:+,}$k"; [ -z "$default_id" ] && default_id="$k"; fi
done
emit SSH_KEYS "${keys:-}"
emit DEFAULT_IDENTITY "${default_id:-}"

# --- Guess the laptop username from authorized_keys comments ---------------
guess=""; comments=""
if [ -f "$HOME/.ssh/authorized_keys" ]; then
  comments=$(awk 'NF{print $NF}' "$HOME/.ssh/authorized_keys" | paste -sd, -)
  guess=$(awk 'NF{print $NF}' "$HOME/.ssh/authorized_keys" | grep -iE '@.*(mac|book)' | head -1 | sed -E 's/@.*//')
  [ -z "$guess" ] && guess=$(awk 'NF{print $NF}' "$HOME/.ssh/authorized_keys" | grep -E '@' | head -1 | sed -E 's/@.*//')
fi
emit LAPTOP_USER_GUESS "${guess:-}"
emit AUTHORIZED_KEYS_COMMENTS "${comments:-}"

# --- Existing ssh_config aliases that point at loopback (prior harness) ----
aliases=""
if [ -f "$HOME/.ssh/config" ]; then
  aliases=$(awk 'tolower($1)=="host"{h=$2} tolower($1)=="hostname" && ($2=="127.0.0.1"||$2=="localhost"){print h}' \
    "$HOME/.ssh/config" | paste -sd, -)
fi
emit LOOPBACK_SSH_ALIASES "${aliases:-}"

# --- Does sshd allow reverse forwarding? (best effort) ---------------------
fwd="default-yes"
if grep -qiE '^[[:space:]]*AllowTcpForwarding[[:space:]]+(no|local)\b' /etc/ssh/sshd_config 2>/dev/null; then
  fwd="restricted-needs-attention"
fi
emit SSHD_TCP_FORWARDING "$fwd"

note "== probe done =="
