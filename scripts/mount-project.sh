#!/usr/bin/env bash
# remote-harness / mount-project.sh
# Mount a laptop directory (via `ssh <alias>`) onto a LOCAL path with sshfs so the agent edits
# it as local files (changes land on the laptop). The default mountpoint is the CURRENT
# directory (your Claude Code project dir) — and it must be EMPTY, so the remote project can
# cleanly become the project root and the mount doesn't hide existing files. Use --unmount to
# detach. Prints KEY=VALUE.
#
#   mount-project.sh --alias NAME --remote-path /path [--mountpoint DIR] [--force]
#   mount-project.sh --alias NAME --unmount [--mountpoint DIR]
set -uo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }
note() { printf '%s\n' "$*" >&2; }

sshfs_install_hint(){   # the right install command for THIS box's OS / package manager
  case "$(uname -s 2>/dev/null)" in
    Darwin) printf 'brew install macos-fuse-t/homebrew-cask/fuse-t && brew install macos-fuse-t/homebrew-cask/sshfs-fuse-t  (no kernel extension / no reduced security)';;
    *) if   command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y sshfs'
       elif command -v dnf     >/dev/null 2>&1; then printf 'sudo dnf install -y fuse-sshfs'
       elif command -v pacman  >/dev/null 2>&1; then printf 'sudo pacman -S --noconfirm sshfs'
       elif command -v zypper  >/dev/null 2>&1; then printf 'sudo zypper install -y sshfs'
       elif command -v apk     >/dev/null 2>&1; then printf 'sudo apk add sshfs'
       else printf "install 'sshfs' with your package manager"; fi;;
  esac
}

ALIAS="" RPATH="" MP="" UNMOUNT=0 FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --alias)       ALIAS="$2"; shift 2;;
    --remote-path) RPATH="$2"; shift 2;;
    --mountpoint)  MP="$2"; shift 2;;
    --unmount)     UNMOUNT=1; shift;;
    --force)       FORCE=1; shift;;
    *) shift;;
  esac
done
[ -n "$ALIAS" ] || { note "usage: mount-project.sh --alias NAME --remote-path /path [--mountpoint DIR] [--force]"; note "       mount-project.sh --alias NAME --unmount [--mountpoint DIR]"; exit 2; }

# Default mountpoint = current directory (the Claude Code project dir).
[ -n "$MP" ] || MP="$PWD"

OS="$(uname -s 2>/dev/null || echo unknown)"
# The sshfs binary. On macOS the no-kext FUSE-T build (brew macos-fuse-t/homebrew-cask/sshfs-fuse-t)
# may install as `sshfs` or `sshfs-fuse-t`; prefer plain `sshfs` if present.
SSHFS_BIN=""; for c in sshfs sshfs-fuse-t; do command -v "$c" >/dev/null 2>&1 && { SSHFS_BIN="$c"; break; }; done

is_mounted() {
  if command -v mountpoint >/dev/null 2>&1; then mountpoint -q "$1" && return 0; fi
  mount 2>/dev/null | grep -qF " $1 "
}
# Is the mount at $1 actually ALIVE (not a stale/dead sshfs endpoint left by a dropped tunnel)?
mount_live() {
  if command -v timeout >/dev/null 2>&1; then timeout 5 ls "$1" >/dev/null 2>&1
  else ls "$1" >/dev/null 2>&1; fi
}
# Best-effort: the source (alias:/path) currently mounted at $1, from the mount table.
mounted_source() { mount 2>/dev/null | awk -v mp=" $1 " 'index($0,mp){print $1; exit}'; }
do_unmount() { fusermount -u "$1" 2>/dev/null || fusermount3 -u "$1" 2>/dev/null || umount "$1" 2>/dev/null || umount -l "$1" 2>/dev/null; }

if [ "$UNMOUNT" = 1 ]; then
  do_unmount "$MP" || true
  if is_mounted "$MP"; then emit STATUS unmount-failed; emit ERROR "still mounted ($MP) — busy?"
  else emit STATUS unmounted; fi
  emit MOUNTPOINT "$MP"
  exit 0
fi

[ -n "$RPATH" ] || { note "need --remote-path"; exit 2; }

if [ -z "$SSHFS_BIN" ]; then
  emit STATUS need-sshfs; emit INSTALL_CMD "$(sshfs_install_hint)"
  note "sshfs is not installed. Install it once (the user runs the command above), then re-run."
  exit 3
fi

if is_mounted "$MP"; then
  want="$ALIAS:$RPATH"; have=""
  # On macOS/FUSE-T the mount source is an NFS loopback (not alias:path), so source-matching is
  # unreliable there. The mount table is whitespace-delimited too, so a source containing spaces
  # can't be parsed from $1 — in both cases skip the source match and rely on liveness only (else a
  # live, correct mount on a spaced path would be misread as "points elsewhere" and needlessly remounted).
  if [ "$OS" != Darwin ]; then
    case "$want" in
      *[[:space:]]*) ;;                       # spaced source: unparseable from the mount table
      *) have="$(mounted_source "$MP")";;
    esac
  fi
  # Reuse only a LIVE mount that points at the requested project; otherwise drop the stale/wrong
  # one and remount fresh (fixes the dropped-tunnel re-run that used to launch into a dead dir).
  if mount_live "$MP" && { [ -z "$have" ] || [ "$have" = "$want" ]; }; then
    emit STATUS already-mounted; emit MOUNTPOINT "$MP"; emit REMOTE "$want"
    exit 0
  fi
  note "Existing mount at $MP is stale or points elsewhere (${have:-unknown}) — remounting as $want."
  do_unmount "$MP" || true
fi

mkdir -p "$MP"
# SAFETY: refuse to mount onto a non-empty directory — sshfs would HIDE its contents, and for
# project-dir mounting the target must be empty so the remote project becomes the project root.
if [ "$FORCE" != 1 ] && [ -n "$(ls -A "$MP" 2>/dev/null)" ]; then
  emit STATUS not-empty
  emit MOUNTPOINT "$MP"
  note "Refusing to mount onto non-empty dir: $MP"
  note "Start Claude Code in a fresh EMPTY directory dedicated to this project and mount there,"
  note "or pass --force to override (will hide the current contents while mounted)."
  exit 4
fi

err="$(mktemp)"
# reconnect + keepalives so brief tunnel hiccups self-heal. idmap=user (libfuse sshfs) maps the
# remote uid → ours; omitted on macOS, where FUSE-T's sshfs mounts via NFS and doesn't accept it.
# We deliberately KEEP sshfs's default attribute/dir caching (no cache_timeout=0): disabling it
# slows stat-heavy operations — git status, editor file-watchers, tree-scanning builds — noticeably
# over the tunnel. The trade-off is a brief window where a just-written edit may not yet be visible
# to a remote `ssh <alias> 'cd … && build'`; the injected rule tells the agent to simply re-run the
# command once if a build fails right after an edit.
case "$OS" in
  Darwin) SSHFS_OPTS="reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks";;
  *)      SSHFS_OPTS="reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks,idmap=user";;
esac
if "$SSHFS_BIN" "$ALIAS:$RPATH" "$MP" -o "$SSHFS_OPTS" 2>"$err"; then
  emit STATUS mounted
  emit MOUNTPOINT "$MP"
  emit REMOTE "$ALIAS:$RPATH"
  [ -d "$MP/.git" ] && emit GIT_BRANCH "$(git -C "$MP" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
  # Claude Code reads CLAUDE.md, not AGENTS.md — flag if the project ships only AGENTS.md.
  [ -f "$MP/AGENTS.md" ] && [ ! -e "$MP/CLAUDE.md" ] && emit AGENTS_MD_ONLY 1
else
  emit STATUS failed
  emit ERROR "$(tr '\n' ' ' < "$err" 2>/dev/null | sed 's/  */ /g' | cut -c1-300)"
fi
rm -f "$err" 2>/dev/null || true
