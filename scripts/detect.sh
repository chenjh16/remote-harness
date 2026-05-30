#!/usr/bin/env bash
# remote-harness / detect.sh
# Read-only environment probe. Makes NO changes. Prints KEY=VALUE lines on stdout
# for the agent to parse, plus a human summary on stderr.
set -uo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }
note() { printf '%s\n' "$*" >&2; }

# Raw "local address" column of every listening TCP socket, across environments:
# ss (iproute2) → netstat (GNU or BSD/macOS) → lsof. Tolerates both `host:PORT` and BSD `host.PORT`.
listening_addrs() {
  if   command -v ss      >/dev/null 2>&1; then ss -tlnH 2>/dev/null | awk '{print $4}'
  elif command -v netstat >/dev/null 2>&1; then netstat -an 2>/dev/null | awk '/^tcp/ && /LISTEN/{print $4}'
  elif command -v lsof    >/dev/null 2>&1; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}'
  fi
}
# Sorted, unique list of listening TCP port numbers (any address).
listening_ports() {
  listening_addrs | sed -E 's/.*[:.]([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un
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
low=$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)         # Linux
[ -z "$low" ] && low=$(sysctl -n net.inet.ip.portrange.first 2>/dev/null)          # macOS/BSD
low=${low:-32768}
emit EPHEMERAL_LOW "$low"

# --- Suggest a port: prefer a FREE high port ending in "22" (below the -----
# --- ephemeral floor, distinctive & ssh-mnemonic); else any free high port -
# --- (the fallback is virtually never needed). -----------------------------
inuse_ports="$(listening_ports)"
free_port() { ! printf '%s\n' "$inuse_ports" | grep -qx "$1"; }
suggested=""
hi=$(( low - 1 )); lobound=2000; [ "$lobound" -ge "$low" ] && lobound=1025
# pass 1: highest free port whose last two digits are "22"
p=$(( (hi / 100) * 100 + 22 )); [ "$p" -gt "$hi" ] && p=$(( p - 100 ))
while [ "$p" -ge "$lobound" ]; do
  free_port "$p" && { suggested="$p"; break; }
  p=$(( p - 100 ))
done
# pass 2 (fallback): highest free port, any ending
if [ -z "$suggested" ]; then
  p="$hi"
  while [ "$p" -ge "$lobound" ]; do
    free_port "$p" && { suggested="$p"; break; }
    p=$(( p - 1 ))
  done
fi
emit SUGGESTED_PORT "$suggested"

# --- Existing loopback listeners (possible prior tunnels) ------------------
existing=$(listening_addrs \
  | grep -E '127\.0\.0\.1[:.]|\[::1\][:.]|::1\.' \
  | sed -E 's/.*[:.]([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un \
  | awk -v lo="$low" '$1>1024 && $1<lo' | paste -sd, -)
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
if grep -qiE '^[[:space:]]*AllowTcpForwarding[[:space:]]+(no|local)([[:space:]]|$)' /etc/ssh/sshd_config 2>/dev/null; then
  fwd="restricted-needs-attention"
fi
emit SSHD_TCP_FORWARDING "$fwd"

note "== probe done =="
