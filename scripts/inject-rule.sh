#!/usr/bin/env bash
# remote-harness / inject-rule.sh — RUN ON THE BOX (where the agent launches).
# The launched agent works in an sshfs mount of the laptop's code, but this box may lack the
# project's toolchain. This injects a rule — "run builds/tests/linters/installs on the LAPTOP" —
# SCOPED TO THIS SESSION/PROJECT (no global instructions file → other projects on the same box are
# unaffected). Per agent it uses that CLI's cleanest scoped channel:
#   claude   → --append-system-prompt-file <rule>   (session-only flag; nothing on disk to clean up
#              beyond the box-side rule file; never touches the mounted repo)
#   opencode → OPENCODE_CONFIG=<session config: instructions[+permission=allow if yolo]>  (env;
#              never touches the mounted repo)
#   codex    → CODEX_HOME=<session home>  (env; codex relocates auth/config/state under CODEX_HOME
#              — `codex doctor` confirms CODEX_HOME is honored — and reads $CODEX_HOME/AGENTS.md as
#              home-level global instructions). We symlink your real ~/.codex into the session home
#              and compose AGENTS.md = your global AGENTS.md + our rule, so only THIS launch sees it.
#              Also passes `-c sandbox_workspace_write.network_access=true` because codex's default
#              sandbox blocks network — otherwise the rule's `ssh <box> ...` to the laptop is denied.
#              The project's own AGENTS.md is still read additively; the mounted repo is never touched.
#
#   inject-rule.sh on  <agent> <laptop_path> <box_alias> <box_mountpoint> [yolo:0|1]
#   inject-rule.sh off <agent> <box_mountpoint>
#
# 'on'  prints: RH_STATUS=INJECTED  RH_LAUNCH_ENV=<env prefix>  RH_LAUNCH_FLAGS=<trailing flags>
# 'off' prints: RH_STATUS=RESTORED | NOOP        (RH_STATUS=ERROR on failure)
# Box-side per-session artifacts live under $RH_HOME/.sessions/<key> (key derived from mountpoint),
# so 'on'/'off' agree without extra state and concurrent harness sessions don't clash.
set -uo pipefail

session_dir() {  # $1 = mountpoint (session key) -> box-side per-session dir
  key="$(printf '%s' "${1:-default}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  printf '%s/.sessions/%s' "${RH_HOME:-$HOME/.remote-harness}" "$key"
}

# Emit a few concrete example commands (one per line) for the project at $1 (mountpoint), by
# sniffing its manifest files. Falls back to generic placeholders if the stack is unknown.
detect_cmds() {
  m="$1"
  if   [ -n "$m" ] && [ -f "$m/package.json" ]; then
    pm=npm
    [ -f "$m/yarn.lock" ]      && pm=yarn
    [ -f "$m/pnpm-lock.yaml" ] && pm=pnpm
    [ -f "$m/bun.lockb" ]      && pm=bun
    printf '%s install\n%s run build\n%s test\n' "$pm" "$pm" "$pm"
  elif [ -n "$m" ] && [ -f "$m/Cargo.toml" ]; then
    printf 'cargo build\ncargo test\ncargo run\n'
  elif [ -n "$m" ] && [ -f "$m/go.mod" ]; then
    printf 'go build ./...\ngo test ./...\n'
  elif [ -n "$m" ] && { [ -f "$m/pyproject.toml" ] || [ -f "$m/requirements.txt" ] || [ -f "$m/setup.py" ]; }; then
    if [ -f "$m/requirements.txt" ]; then printf 'pip install -r requirements.txt\n'; else printf 'pip install -e .\n'; fi
    printf 'pytest\n'
  elif [ -n "$m" ] && [ -f "$m/Gemfile" ]; then
    printf 'bundle install\nbundle exec rake test\n'
  elif [ -n "$m" ] && { [ -f "$m/Makefile" ] || [ -f "$m/makefile" ]; }; then
    printf 'make\nmake test\n'
  else
    printf '<install deps>\n<build>\n<test>\n'
  fi
}

write_rule() {  # $1=outfile  $2=laptop_path  $3=box_alias  $4=mountpoint
  cmds="$(detect_cmds "$4")"
  lpq="$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"   # path with single quotes escaped, for the 'cd ...' examples
  {
    printf '# IMPORTANT — Remote dev harness rule (READ BEFORE RUNNING ANY COMMAND)\n\n'
    printf '**Your working directory is an sshfs mount of `%s` on the user'\''s laptop — this box is\n' "$2"
    printf 'NOT the project'\''s runtime.** It may lack the toolchain, and ANYTHING you write into this\n'
    printf 'dir (node_modules, .venv, target/, build output) is written back over the mount to the\n'
    printf 'laptop and may be built for the WRONG OS/arch — silently corrupting the user'\''s environment.\n\n'
    printf '**MANDATORY RULE — no exceptions:** run EVERY build, test, linter, formatter, type-check,\n'
    printf 'dependency install, code generator, script, and the app itself **ON THE LAPTOP**, never on\n'
    printf 'this box. Run them like this:\n\n'
    printf '    ssh %s '\''cd %s && <command>'\''\n\n' "$3" "$lpq"
    printf 'For this project, that means (for example):\n\n'
    printf '%s\n' "$cmds" | while IFS= read -r c; do
      [ -n "$c" ] && printf '    ssh %s '\''cd %s && %s'\''\n' "$3" "$lpq" "$c"
    done
    printf '\n'
    printf '**NEVER run installs or builds locally on this box** (`npm install`, `pip install`,\n'
    printf '`cargo build`, `make`, etc.) — it pollutes the mounted dir and corrupts the laptop'\''s\n'
    printf 'dependencies with binaries built for this box'\''s OS/arch. The ONLY things safe to do\n'
    printf 'locally are read-only: reading and editing files, `grep`, `git status` / `git diff`.\n'
    printf 'If a command needs the toolchain, or a local build/test/run fails, do NOT try to work\n'
    printf 'around it on this box — re-run it on the laptop via the `ssh %s ...` form above.\n' "$3"
  } > "$1"
}

case "${1:-}" in
  on)
    agent="${2:-}"; lp="${3:-}"; ba="${4:-}"; mp="${5:-}"; yolo="${6:-0}"
    case "$agent" in claude|codex|opencode) ;; *) echo "RH_STATUS=ERROR"; exit 2;; esac
    [ -n "$lp" ] && [ -n "$ba" ] || { echo "RH_STATUS=ERROR"; exit 2; }
    SD="$(session_dir "$mp")"
    rm -rf "$SD" 2>/dev/null || true
    mkdir -p "$SD" 2>/dev/null || { echo "RH_STATUS=ERROR"; exit 1; }
    RULE="$SD/rule.md"
    write_rule "$RULE" "$lp" "$ba" "$mp" || { echo "RH_STATUS=ERROR"; exit 1; }

    env_out=""; flags_out=""
    case "$agent" in
      claude)
        flags_out="--append-system-prompt-file $RULE"
        ;;
      opencode)
        # OPENCODE_CONFIG is merged ADDITIVELY on top of the user's global + project configs, so we
        # only write a minimal session layer (instructions + permission on yolo). No jq, no copying
        # the user's config — that avoided a crash on a non-array `instructions` and a stale config
        # snapshot overriding a project-local opencode.json.
        CFG="$SD/opencode.json"
        [ "$yolo" = 1 ] && perm='"permission": "allow", ' || perm=''
        printf '{ "$schema": "https://opencode.ai/config.json", %s"instructions": ["%s"] }\n' "$perm" "$RULE" > "$CFG"
        env_out="OPENCODE_CONFIG=$CFG"
        ;;
      codex)
        # Per-session CODEX_HOME: symlink the real ~/.codex entries (auth.json, config.toml, state
        # DBs, ...) so codex authenticates and persists normally, but supply our composed AGENTS.md
        # as the home-level global instructions. Scoped to this launch's env; no global/repo writes.
        CH="$SD/codex-home"; mkdir -p "$CH"
        if [ -d "$HOME/.codex" ]; then
          for x in "$HOME/.codex"/* "$HOME/.codex"/.[!.]*; do
            [ -e "$x" ] || continue
            bn="$(basename "$x")"
            case "$bn" in AGENTS.md|AGENTS.override.md) continue;; esac   # composed below, not symlinked
            ln -sfn "$x" "$CH/$bn" 2>/dev/null || true
          done
        fi
        # Preserve the user's personal global guidance AND append our rule (don't silently drop it).
        { [ -f "$HOME/.codex/AGENTS.md" ] && { cat "$HOME/.codex/AGENTS.md"; printf '\n\n'; }
          cat "$RULE"; } > "$CH/AGENTS.md" 2>/dev/null || cp "$RULE" "$CH/AGENTS.md"
        env_out="CODEX_HOME=$CH"
        # codex's default workspace-write sandbox disables network, which would block the rule's
        # `ssh <box> 'cd ... && <cmd>'` to the laptop. Grant network for this session so those run.
        # (Under --yolo the bypass flag already drops the sandbox, so this is redundant-but-harmless.)
        flags_out="-c sandbox_workspace_write.network_access=true"
        ;;
    esac
    printf 'RH_STATUS=INJECTED\n'
    printf 'RH_LAUNCH_ENV=%s\n'   "$env_out"
    printf 'RH_LAUNCH_FLAGS=%s\n' "$flags_out"
    ;;
  off)
    mp="${3:-}"; SD="$(session_dir "$mp")"
    # All agents' artifacts (rule file, opencode config, codex home) live in the session dir, and
    # none of them touched the mounted repo — so cleanup is just removing that dir.
    if [ -d "$SD" ]; then
      rm -rf "$SD" 2>/dev/null && echo "RH_STATUS=RESTORED" || echo "RH_STATUS=ERROR"
    else
      echo "RH_STATUS=NOOP"
    fi
    ;;
  *)
    echo "usage: inject-rule.sh on <agent> <laptop_path> <box_alias> <box_mountpoint> [yolo] | off <agent> <box_mountpoint>" >&2
    echo "RH_STATUS=ERROR"; exit 2;;
esac
