#!/usr/bin/env bash
# remote-harness — manage the /remote-harness entry for your coding agents.
#
# Usage:
#   ./manage.sh [agents...]              install by COPYING (production)
#   ./manage.sh --dev [agents...]        install by SYMLINK to this repo (edits here go live)
#   ./manage.sh --uninstall [agents...]  remove installed files/links
#   ./manage.sh --help
#
#   agents: claude codex opencode   (default: all)
#
# Uninstall never touches your ~/.ssh tunnel config or any sshfs mounts.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RH_HOME="${RH_HOME:-$HOME/.remote-harness}"
CLAUDE_DIR="$HOME/.claude/skills/remote-harness"          # Claude Code: native Agent Skill
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}/skills/remote-harness"     # Codex: native skill (type: remote-harness)
OPENCODE_FILE="$HOME/.config/opencode/command/remote-harness.md"  # opencode: custom command

usage() { sed -n '4,12p' "${BASH_SOURCE[0]}" | cut -c3-; }

MODE=copy ACTION=install targets=""
for a in "$@"; do
  case "$a" in
    --dev)                 MODE=dev ;;
    --uninstall|uninstall) ACTION=uninstall ;;
    --help|-h)             usage; exit 0 ;;
    claude|codex|opencode) targets="$targets $a" ;;
    all|--all)             targets="$targets all" ;;
    *) echo "unknown arg: $a (see --help)" >&2; exit 2 ;;
  esac
done
[ -n "$targets" ] || targets="all"
want() { case " $targets " in *" all "*) return 0;; *" $1 "*) return 0;; *) return 1;; esac; }

place_file() {  # src dest — symlink (dev) or copy (production)
  rm -rf "$2"; mkdir -p "$(dirname "$2")"
  if [ "$MODE" = dev ]; then ln -s "$1" "$2"; else cp "$1" "$2"; fi
}
place_scripts() {  # destdir
  rm -rf "$1"
  if [ "$MODE" = dev ]; then
    mkdir -p "$(dirname "$1")"; ln -s "$SRC/scripts" "$1"
  else
    mkdir -p "$1"; cp "$SRC"/scripts/*.sh "$1"/; chmod +x "$1"/*.sh
  fi
}
rm_path() {  # remove a file/dir/symlink if present (symlinks unlinked, never followed)
  if [ -e "$1" ] || [ -L "$1" ]; then rm -rf "$1"; echo "  ✓ removed $1"; fi
}

if [ "$ACTION" = uninstall ]; then
  echo "remote-harness uninstall (targets:$targets)"
  want claude   && rm_path "$CLAUDE_DIR"    || true
  want codex    && rm_path "$CODEX_DIR"     || true
  want opencode && rm_path "$OPENCODE_FILE" || true
  # Drop the shared core only when removing everything (other launchers still reference it).
  if want claude && want codex && want opencode; then rm_path "$RH_HOME"; fi
  echo "done. (Your ~/.ssh tunnel alias and any sshfs mounts were left untouched.)"
  exit 0
fi

echo "remote-harness install  mode=$MODE  targets:$targets"
echo "  source: $SRC"

mkdir -p "$RH_HOME"
place_file "$SRC/SKILL.md" "$RH_HOME/SKILL.md"
place_file "$SRC/SKILL.cn.md" "$RH_HOME/SKILL.cn.md"
place_scripts "$RH_HOME/scripts"
# reference docs, read on demand at runtime via $RH/reference/*.md (incl. *.cn.md)
rm -rf "$RH_HOME/reference"
if [ "$MODE" = dev ]; then ln -s "$SRC/reference" "$RH_HOME/reference"
else mkdir -p "$RH_HOME/reference"; cp "$SRC"/reference/*.md "$RH_HOME/reference"/; fi
echo "  ✓ core ($MODE) → $RH_HOME"

if want claude; then
  rm -rf "$CLAUDE_DIR"; mkdir -p "$CLAUDE_DIR"
  place_file "$SRC/SKILL.md" "$CLAUDE_DIR/SKILL.md"
  echo "  ✓ Claude Code skill ($MODE) → $CLAUDE_DIR/SKILL.md"
fi
if want codex; then
  # codex-cli has no custom /slash commands; it loads native skills from $CODEX_HOME/skills/<name>/.
  # Install the shared SKILL.md as a skill — invoke by TYPING `remote-harness` (no slash).
  rm -rf "$CODEX_DIR"; mkdir -p "$CODEX_DIR"
  place_file "$SRC/SKILL.md" "$CODEX_DIR/SKILL.md"
  echo "  ✓ Codex skill ($MODE)       → $CODEX_DIR/SKILL.md  (invoke: type 'remote-harness', no slash)"
fi
if want opencode; then
  place_file "$SRC/adapters/opencode.md" "$OPENCODE_FILE"
  echo "  ✓ opencode command ($MODE)  → $OPENCODE_FILE"
fi

echo
[ "$MODE" = dev ] && echo "DEV install: edits in $SRC are live immediately." || true
echo "Done. Start it in your agent:  /remote-harness  (Claude Code / opencode)  ·  type 'remote-harness' (no slash) in Codex"
echo "  reverse: agent on a remote box, code on your laptop  |  forward: agent local, code on a remote server"
