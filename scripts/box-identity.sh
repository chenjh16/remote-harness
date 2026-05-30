#!/usr/bin/env bash
# remote-harness / box-identity.sh
# Offline analysis of THIS box: print the laptop-setup.sh args that let the laptop side
# IDENTIFY this box (hostname, login user, and SSH host-key fingerprints — the decisive
# anchor for matching the laptop's known_hosts). The skill bakes this into the one-shot
# laptop command.
#   box-identity.sh --port <PORT>
set -uo pipefail
PORT=""
while [ $# -gt 0 ]; do case "$1" in --port) PORT="$2"; shift 2;; *) shift;; esac; done

args=""
[ -n "$PORT" ] && args="--port $PORT"
args="$args --box-hostname $(hostname 2>/dev/null || echo unknown)"
args="$args --box-user $(id -un 2>/dev/null || whoami 2>/dev/null || echo unknown)"
for f in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
  [ -f "$f" ] || continue
  fp=$(ssh-keygen -lf "$f" 2>/dev/null | awk '{print $2}')
  [ -n "$fp" ] && args="$args --box-fp $fp"
done
printf '%s\n' "$args"
