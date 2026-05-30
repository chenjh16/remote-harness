#!/usr/bin/env bash
# remote-harness / _common.sh — shared helpers, SOURCED (not executed) by the two setup scripts:
#   laptop-setup.sh  (reverse: agent on a remote box, code on the laptop — reverse tunnel)
#   local-setup.sh   (forward: agent local, code on a directly-reachable remote server)
# Both source it via:  . "$(dirname "$0")/_common.sh"
# For the reverse flow the skill's one-command fetches THIS file next to laptop-setup.sh so the
# laptop (which usually has no install) still finds it. Sets colors + OS vars at source time and
# defines output/quoting/ssh-config helpers. Sourced files must NOT set -e or exit.

# ---- colors (ANSI, only when stdout is a real terminal) --------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1 \
     && [ "$(tput colors 2>/dev/null)" -ge 8 ]; then
  _B=$(tput bold 2>/dev/null)     # bold
  _G=$(tput setaf 2 2>/dev/null)  # green
  _Y=$(tput setaf 3 2>/dev/null)  # yellow
  _C=$(tput setaf 6 2>/dev/null)  # cyan
  _R=$(tput setaf 1 2>/dev/null)  # red
  _D=$(tput setaf 4 2>/dev/null)  # dim blue (for headers)
  _0=$(tput sgr0 2>/dev/null)     # reset
else
  _B="" _G="" _Y="" _C="" _R="" _D="" _0=""
fi

# ---- output helpers --------------------------------------------------------
say()  { printf '%s\n' "$*"; }
ok()   { printf "  ${_G}✓${_0} %s\n" "$*"; }
warn() { printf "  ${_Y}⚠${_0} %s\n" "$*"; }
err()  { printf "  ${_R}✗${_0} %s\n" "$*" >&2; }
hdr()  { printf "\n${_B}${_D}── %s${_0}\n" "$*"; }
sep()  { printf '\n'; }
# Yes/no prompt on the tty. Honors a caller-set ASSUME_YES=1 (non-interactive).
ask() {
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  printf "${_Y}?${_0} %s [y/N] " "$1" >/dev/tty
  local a=""; read -r a </dev/tty || true
  case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

# Shell-quote a value for SAFE interpolation into a remote command string: wrap in single quotes,
# escaping any embedded single quote as '\''. Prevents paths with apostrophes (legal on macOS) from
# breaking — or injecting into — the ssh command strings the setup scripts build.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ---- OS detection (sets OS / PLAT / IS_WSL at source time) -----------------
OS="$(uname -s 2>/dev/null || echo unknown)"; IS_WSL=0
case "$OS" in
  Darwin) PLAT=macos;;
  Linux)  PLAT=linux; grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && IS_WSL=1;;
  *)      PLAT=other;;
esac

# ---- parse an ssh-args / alias string into V_HOST/V_PORT/V_USER/V_IDENTITY --
# Accepts either a bare alias ("myserver") or raw args ("-p 2222 user@host -i ~/.k"). The value is
# intentionally word-split (unquoted) — NOT eval'd — so a crafted/mistyped string can't run locally.
parse_via() {
  V_HOST="" V_PORT="" V_USER="" V_IDENTITY=""
  [ -n "${1:-}" ] || return 0
  set -- $1
  [ "${1:-}" = "ssh" ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -p)  V_PORT="${2:-}"; shift 2 || shift;;
      -p*) V_PORT="${1#-p}"; shift;;
      -l)  V_USER="${2:-}"; shift 2 || shift;;
      -i)  V_IDENTITY="${2:-}"; shift 2 || shift;;
      -i*) V_IDENTITY="${1#-i}"; shift;;
      -o|-F|-J|-b|-c|-m|-w|-D|-L|-R|-W|-E|-Q|-S) shift 2 || shift;;
      -*)  shift;;
      *)   if [ -z "$V_HOST" ]; then case "$1" in *@*) V_USER="${1%@*}"; V_HOST="${1##*@}";; *) V_HOST="$1";; esac; fi; shift;;
    esac
  done
}

# True if a "Host <name>" block exists in $CFG (exact token match, ignoring inline comments).
block_exists() { awk -v h="$1" '/^[ \t]*[Hh][Oo][Ss][Tt][ \t]/{for(i=2;i<=NF;i++){if($i=="#")break;if($i==h)f=1}}END{exit !f}' "$CFG"; }
# Drop the whole "Host <name>" block (Host line .. next Host / EOF) from $CFG, in place.
remove_host_block() {
  awk -v h="$1" '
    function H(s){return s~/^[ \t]*[Hh][Oo][Ss][Tt][ \t]/}
    H($0){drop=0;n=split($0,a,/[ \t]+/);for(i=2;i<=n;i++){if(a[i]=="#")break;if(a[i]==h)drop=1}}
    drop!=1{print}' "$CFG" > "$CFG.rhtmp" && mv "$CFG.rhtmp" "$CFG"
}
# Create-or-replace a managed Host block in $CFG from the parsed V_* vars. $1 = alias name;
# any further args are extra indented lines appended verbatim (e.g. a RemoteForward line, or
# ControlMaster/keepalive lines). Idempotent (removes any prior block of the same name first).
write_managed_alias() {
  _wma_alias="$1"; shift
  remove_host_block "$_wma_alias"
  { printf '\nHost %s\n' "$_wma_alias"
    [ -n "${V_HOST:-}" ]                            && printf '    HostName %s\n' "$V_HOST"
    [ -n "${V_PORT:-}" ] && [ "${V_PORT}" != 22 ]   && printf '    Port %s\n' "$V_PORT"
    [ -n "${V_USER:-}" ]                            && printf '    User %s\n' "$V_USER"
    [ -n "${V_IDENTITY:-}" ]                        && printf '    IdentityFile %s\n' "$V_IDENTITY"
    for _wma_line in "$@"; do printf '%s\n' "$_wma_line"; done
  } >> "$CFG"
}
