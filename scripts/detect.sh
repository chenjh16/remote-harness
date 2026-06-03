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

# --- Identify the REAL user behind this (possibly shared) box account -------
# On a shared box account several people each run remote-harness; we namespace the reverse tunnel
# (ssh alias + port) per real user so their tunnels don't collide or, worse, get cross-wired to the
# wrong laptop. Guess that namespace from, in priority order:
#   (1) the public-key COMMENT this very session authenticated with — needs sshd `ExposeAuthInfo
#       yes` (usually OFF), so often unavailable, but it's the most precise when present;
#   (2) the first path component of $PWD under $HOME — the soft "~/<name>/<project>" convention;
#   (3) a laptop-user guess from authorized_keys comments.
# This is only a PRE-FILL; the agent MUST confirm it (see SKILL.md "Confirm, don't infer").
sanitize_ns() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | sed 's/^[._-]*//; s/[._-]*$//'; }

comments=""; akguess=""
if [ -f "$HOME/.ssh/authorized_keys" ]; then
  comments=$(awk 'NF{print $NF}' "$HOME/.ssh/authorized_keys" | paste -sd, -)
  akguess=$(awk 'NF{print $NF}' "$HOME/.ssh/authorized_keys" | grep -iE '@.*(mac|book)' | head -1 | sed -E 's/@.*//')
  [ -z "$akguess" ] && akguess=$(awk 'NF{print $NF}' "$HOME/.ssh/authorized_keys" | grep -E '@' | head -1 | sed -E 's/@.*//')
fi

# (1) the session's authenticating public key -> its authorized_keys COMMENT. The FULL comment
# (e.g. alice@macbook) is the most unique per-machine identity, so it is the primary guess; the
# friendlier local part (alice) is offered as an alternative candidate.
# Mechanism: sshd `ExposeAuthInfo yes` (default OFF) writes the session's auth lines to a TEMP FILE
# and exposes that file's PATH in $SSH_USER_AUTH (NOT the content). Each line looks like
# `publickey ssh-ed25519 <base64>`. (A few setups may instead place the lines directly in
# $SSH_AUTH_INFO_0 — accepted as a fallback.) Without ExposeAuthInfo the signal is simply absent and
# the launch-dir / authorized_keys heuristics carry the namespace.
ru_authkey=""; ru_authkey_local=""
authinfo=""
if [ -n "${SSH_USER_AUTH:-}" ] && [ -r "${SSH_USER_AUTH:-}" ]; then
  authinfo="$(cat "$SSH_USER_AUTH" 2>/dev/null)"          # $SSH_USER_AUTH is a PATH — read the file
elif [ -n "${SSH_AUTH_INFO_0:-}" ]; then
  authinfo="$SSH_AUTH_INFO_0"                              # fallback: lines provided directly
fi
if [ -n "$authinfo" ] && [ -f "$HOME/.ssh/authorized_keys" ]; then
  sess_key=$(printf '%s\n' "$authinfo" | awk '$1=="publickey"{print $3; exit}')
  if [ -n "$sess_key" ]; then
    # Match the base64 blob as a WHOLE FIELD (robust to '/' and '+' in the key, and to key-option
    # prefixes like command="..."), then take the rest of that line as the comment. Do NOT feed the
    # key to sed/grep-regex — a '/' in the blob would break the s/// command.
    cmt=$(awk -v k="$sess_key" '{for(i=1;i<=NF;i++) if($i==k){s="";for(j=i+1;j<=NF;j++)s=s (j>i+1?" ":"") $j; print s; exit}}' "$HOME/.ssh/authorized_keys")
    if [ -n "$cmt" ]; then
      ru_authkey="$cmt"               # full comment — most unique, rarely collides
      ru_authkey_local="${cmt%%@*}"   # local part — friendlier alternative
    fi
  fi
fi

# (2) first path component of the launch dir under $HOME, unless it's a generic workspace name.
ru_cwd=""
case "$PWD/" in
  "$HOME"/?*/)
    rest=${PWD#"$HOME"/}; first=${rest%%/*}
    case "$first" in
      work|workspace|Workspace|projects|Projects|project|code|Code|src|Src|repos|repo|git|dev|Dev|Documents|Desktop|Downloads|tmp|temp|mnt|home|.cache|.config|.local|.ssh|.remote-harness|remote-harness-mounts) ;;
      *) ru_cwd="$first";;
    esac;;
esac

ru=""; ru_src=none
if   [ -n "$ru_authkey" ]; then ru=$ru_authkey; ru_src=authkey
elif [ -n "$ru_cwd" ];     then ru=$ru_cwd;     ru_src=cwd
elif [ -n "$akguess" ];    then ru=$akguess;    ru_src=authorized_keys
fi
ru=$(sanitize_ns "$ru")
[ -n "$ru" ] || ru_src=none
emit REALUSER_GUESS "$ru"
emit REALUSER_SOURCE "$ru_src"
# All distinct candidates (deduped) so the agent can offer alternatives in its confirmation —
# including BOTH the full key comment and its friendlier local part.
cand=""
for c in "$ru_authkey" "$ru_authkey_local" "$ru_cwd" "$akguess"; do
  c=$(sanitize_ns "$c"); [ -n "$c" ] || continue
  case ",$cand," in *",$c,"*) ;; *) cand="${cand:+$cand,}$c";; esac
done
emit REALUSER_CANDIDATES "$cand"

# --- Ephemeral port floor (pick a fixed tunnel port BELOW this) ------------
low=$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)         # Linux
[ -z "$low" ] && low=$(sysctl -n net.inet.ip.portrange.first 2>/dev/null)          # macOS/BSD
low=${low:-32768}
emit EPHEMERAL_LOW "$low"

# --- Suggest a reverse-tunnel port. With a real-user namespace, derive a STABLE base port from it
# --- (hash -> a ".22" slot in [20022,29922], below the ephemeral floor) so different users land on
# --- different ports and the SAME user reconnects to the SAME port (clean reuse); then probe for a
# --- free slot. Otherwise (or if that range overlaps the ephemeral floor) fall back to the legacy
# --- "highest free port ending in 22". setup-tunnel.sh derives the same way from the CONFIRMED
# --- namespace — KEEP THE SLOT FORMULA (20022 + (cksum%100 ...)*100) IN SYNC with this.
inuse_ports="$(listening_ports)"
free_port() { ! printf '%s\n' "$inuse_ports" | grep -qx "$1"; }
suggested=""
if [ -n "$ru" ] && [ "$low" -gt 29922 ]; then
  bb=$(( $(printf '%s' "$ru" | cksum | awk '{print $1}') % 100 ))
  i=0
  while [ "$i" -lt 100 ]; do
    p=$(( 20022 + ((bb + i) % 100) * 100 ))
    free_port "$p" && { suggested="$p"; break; }
    i=$(( i + 1 ))
  done
fi
if [ -z "$suggested" ]; then
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

# --- Laptop-user guess + authorized_keys comments (harvested above for RU) --
emit LAPTOP_USER_GUESS "${akguess:-}"
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
