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
CODEX_FILE="$HOME/.codex/prompts/remote-harness.md"       # Codex: custom prompt (/remote-harness)
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
  want codex    && rm_path "$CODEX_FILE"    || true
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
place_scripts "$RH_HOME/scripts"
echo "  ✓ core ($MODE) → $RH_HOME"

if want claude; then
  rm -rf "$CLAUDE_DIR"; mkdir -p "$CLAUDE_DIR"
  place_file "$SRC/SKILL.md" "$CLAUDE_DIR/SKILL.md"
  echo "  ✓ Claude Code skill ($MODE) → $CLAUDE_DIR/SKILL.md"
fi
if want codex; then
  place_file "$SRC/adapters/codex.md" "$CODEX_FILE"
  echo "  ✓ Codex prompt ($MODE)      → $CODEX_FILE"
fi
if want opencode; then
  place_file "$SRC/adapters/opencode.md" "$OPENCODE_FILE"
  echo "  ✓ opencode command ($MODE)  → $OPENCODE_FILE"
fi

echo
[ "$MODE" = dev ] && echo "DEV install: edits in $SRC are live immediately." || true
echo "Done. On the remote dev box, inside your coding agent, run:  /remote-harness"
