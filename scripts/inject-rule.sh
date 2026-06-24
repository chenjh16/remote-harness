#!/usr/bin/env bash
# remote-harness / inject-rule.sh — RUN WHERE THE AGENT LAUNCHES.
# The launched agent works in an sshfs mount of the project host's code. This machine may lack that
# project's toolchain/runtime, so this injects a session rule: run builds/tests/linters/installs on
# the project host reached by the supplied SSH alias. The rule is SCOPED TO THIS SESSION/PROJECT (no
# global instructions file → other sessions are unaffected). Per agent it uses that CLI's cleanest
# scoped channel:
#   claude   → --append-system-prompt-file <rule>   (session-only flag; nothing on disk to clean up
#              beyond the box-side rule file; never touches the mounted repo)
#   opencode → OPENCODE_CONFIG=<session config: instructions[+permission=allow if yolo]>  (env;
#              never touches the mounted repo)
#   codex    → -c developer_instructions=<rule>  (session-only CLI config; avoids changing
#              CODEX_HOME, because modern Codex can store ChatGPT credentials in an encrypted
#              keyring keyed by the real home and would prompt for login under a synthetic home).
#              Also passes `-s workspace-write -c sandbox_workspace_write.network_access=true` and
#              a writable root for the session-owned ~/.remote-harness/.sessions dirs because codex's
#              default sandbox blocks network and otherwise prevents ssh from writing its temp
#              known_hosts there. It never makes ~/.ssh writable.
#              The project's own AGENTS.md is still read additively; the mounted repo is never touched.
#
#   inject-rule.sh on  <agent> <project_path_on_host> <host_alias> <mountpoint> [yolo:0|1] [ssh_config]
#   inject-rule.sh off <agent> <mountpoint>
#
# 'on'  prints: RH_STATUS=INJECTED  RH_LAUNCH_ENV=<env prefix>  RH_LAUNCH_FLAGS=<trailing flags>
# 'off' prints: RH_STATUS=RESTORED | NOOP        (RH_STATUS=ERROR on failure)
# Per-session artifacts live under $RH_HOME/.sessions/<key> on the agent machine (key derived from
# mountpoint), so 'on'/'off' agree without extra state and concurrent harness sessions don't clash.
set -uo pipefail

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

safe_ssh_token() {
  case "${1:-}" in
    ""|-*|*[[:space:]]*) return 1;;
    *) return 0;;
  esac
}

session_dir() {  # $1 = mountpoint (session key) -> box-side per-session dir
  key="$(printf '%s' "${1:-default}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  case "$key" in ""|.|..) key=default;; esac   # never let the key escape $RH_HOME/.sessions/ (e.g. "..")
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
    printf '%s install\n%s run build\n%s test\n%s run lint\n%s run format\n' "$pm" "$pm" "$pm" "$pm" "$pm"
  elif [ -n "$m" ] && [ -f "$m/Cargo.toml" ]; then
    printf 'cargo build\ncargo test\ncargo run\ncargo clippy\ncargo fmt --check\n'
  elif [ -n "$m" ] && [ -f "$m/go.mod" ]; then
    printf 'go build ./...\ngo test ./...\ngo vet ./...\ngofmt -l .\n'
  elif [ -n "$m" ] && { [ -f "$m/pyproject.toml" ] || [ -f "$m/requirements.txt" ] || [ -f "$m/setup.py" ]; }; then
    if [ -f "$m/requirements.txt" ]; then printf 'pip install -r requirements.txt\n'; else printf 'pip install -e .\n'; fi
    printf 'pytest\n'
    { [ -f "$m/ruff.toml" ] || [ -f "$m/.ruff.toml" ] || grep -qs 'ruff' "$m/pyproject.toml" 2>/dev/null; } && printf 'ruff check .\n' || true
    [ -f "$m/mypy.ini" ] || grep -qsE '\[(tool\.)?mypy\]' "$m/setup.cfg" "$m/pyproject.toml" 2>/dev/null && printf 'mypy .\n' || true
  elif [ -n "$m" ] && [ -f "$m/pom.xml" ]; then
    if [ -f "$m/mvnw" ]; then mvn=./mvnw; else mvn=mvn; fi
    printf '%s -q compile\n%s test\n%s package\n' "$mvn" "$mvn" "$mvn"
  elif [ -n "$m" ] && { [ -f "$m/build.gradle" ] || [ -f "$m/build.gradle.kts" ] || [ -f "$m/settings.gradle" ] || [ -f "$m/settings.gradle.kts" ]; }; then
    if [ -f "$m/gradlew" ]; then gr=./gradlew; else gr=gradle; fi
    printf '%s build\n%s test\n%s run\n' "$gr" "$gr" "$gr"
  elif [ -n "$m" ] && { ls "$m"/*.sln >/dev/null 2>&1 || ls "$m"/*.csproj >/dev/null 2>&1; }; then
    printf 'dotnet restore\ndotnet build\ndotnet test\n'
  elif [ -n "$m" ] && [ -f "$m/Gemfile" ]; then
    printf 'bundle install\nbundle exec rake test\n'
  elif [ -n "$m" ] && { [ -f "$m/Makefile" ] || [ -f "$m/makefile" ]; }; then
    printf 'make\nmake test\n'
  else
    printf '<install deps>\n<build>\n<test>\n'
  fi
}

toml_basic_string_file() {
  awk '
    BEGIN { printf "\"" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      printf "%s%s", sep, $0
      sep="\\n"
    }
    END { printf "\"" }
  ' "$1"
}

toml_escape_value() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

codex_writable_roots_cfg() {
  _cwr_sd="$1"
  _cwr_ssh_config="${2:-}"
  _cwr_cfg_dir=""
  [ -n "$_cwr_ssh_config" ] && _cwr_cfg_dir="$(dirname "$_cwr_ssh_config" 2>/dev/null || true)"
  printf 'sandbox_workspace_write.writable_roots=["%s"' "$(toml_escape_value "$_cwr_sd")"
  if [ -n "$_cwr_cfg_dir" ] && [ "$_cwr_cfg_dir" != "$_cwr_sd" ]; then
    printf ',"%s"' "$(toml_escape_value "$_cwr_cfg_dir")"
  fi
  printf ']'
}

write_ssh_wrapper() {  # $1=session dir  $2=alias  $3=ssh config path
  sd="$1"; alias_name="$2"; cfg="$3"
  safe_ssh_token "$alias_name" || return 1
  case "$cfg" in ""|*'
'*) return 1;; esac
  real_ssh="$(command -v ssh 2>/dev/null || true)"
  [ -n "$real_ssh" ] || return 1
  bin="$sd/bin"
  mkdir -p "$bin" 2>/dev/null || return 1
  wrapper="$bin/ssh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'real_ssh=%s\n' "$(sq "$real_ssh")"
    printf 'alias_name=%s\n' "$(sq "$alias_name")"
    printf 'cfg=%s\n' "$(sq "$cfg")"
    printf 'need_value=0\n'
    printf 'target=""\n'
    printf 'for arg in "$@"; do\n'
    printf '  if [ "$need_value" = 1 ]; then need_value=0; continue; fi\n'
    printf '  case "$arg" in\n'
    printf '    -F|-F*) exec "$real_ssh" "$@" ;;\n'
    printf '    -b|-c|-D|-E|-e|-I|-i|-J|-L|-l|-m|-O|-o|-p|-Q|-R|-S|-W|-w) need_value=1; continue ;;\n'
    printf '    -b*|-c*|-D*|-E*|-e*|-I*|-i*|-J*|-L*|-l*|-m*|-O*|-o*|-p*|-Q*|-R*|-S*|-W*|-w*) continue ;;\n'
    printf '    -*) continue ;;\n'
    printf '    *) target="$arg"; break ;;\n'
    printf '  esac\n'
    printf 'done\n'
    printf 'if [ "$target" = "$alias_name" ]; then\n'
    printf '  exec "$real_ssh" -F "$cfg" "$@"\n'
    printf 'fi\n'
    printf 'exec "$real_ssh" "$@"\n'
  } > "$wrapper" || return 1
  chmod +x "$wrapper" 2>/dev/null || return 1
  return 0
}

write_rule() {  # $1=outfile  $2=code_path (on $3)  $3=host_alias (where code lives)  $4=mountpoint
  cmds="$(detect_cmds "$4")"
  lpq="$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"   # path with single quotes escaped, for the 'cd ...' examples
  {
    printf '# IMPORTANT — Remote dev harness rule (READ BEFORE RUNNING ANY COMMAND)\n\n'
    printf '**Your working directory is an sshfs mount of `%s` on `%s` — this machine is NOT where\n' "$2" "$3"
    printf 'the project runs.** It may lack the toolchain/runtime, and ANYTHING you write here\n'
    printf '(node_modules, .venv, target/, build output) is written back over the mount to `%s` and\n' "$3"
    printf 'may be built for the WRONG OS/arch — silently corrupting that environment.\n\n'
    printf '**MANDATORY RULE — no exceptions:** run EVERY build, run/start, test, linter, formatter,\n'
    printf 'type-check, language server, debugger, dependency install, code generator, DB migration,\n'
    printf 'and `git commit`/`git push` (their hooks run the toolchain) — and ANY other project tool —\n'
    printf '**on `%s`**, never on this machine. One-shot commands:\n\n' "$3"
    printf '    ssh %s '\''cd %s && <command>'\''\n\n' "$3" "$lpq"
    printf 'For this project, that means (for example):\n\n'
    printf '%s\n' "$cmds" | while IFS= read -r c; do
      [ -n "$c" ] && printf '    ssh %s '\''cd %s && %s'\''\n' "$3" "$lpq" "$c"
    done
    printf '\n'
    printf 'For a long-running process (dev server, file watcher) allocate a TTY, and forward any port\n'
    printf 'you need to reach locally:\n\n'
    printf '    ssh -t -L 3000:127.0.0.1:3000 %s '\''cd %s && <dev server>'\''\n\n' "$3" "$lpq"
    printf '**NEVER run installs/builds/tools on this machine** (`npm install`, `pip install`,\n'
    printf '`cargo build`, `make`, a linter/formatter, a language server, etc.) — it pollutes the mount\n'
    printf 'and corrupts `%s`'\''s deps with wrong-OS/arch binaries. Safe local work is file-oriented:\n' "$3"
    printf 'read files, write/edit files, search with `rg`/`grep`, and use read-only git\n'
    printf '(`git status`/`git diff`/`git log`). Mutating git commands or any command that needs the\n'
    printf 'project toolchain/runtime belong on `%s` via SSH.\n' "$3"
    printf 'If a command needs the toolchain, or a remote run fails right after you edited a file (the\n'
    printf 'mount may not have flushed yet — just re-run it once), do NOT work around it locally — run\n'
    printf 'it on `%s` via the `ssh %s ...` forms above.\n' "$3" "$3"
  } > "$1"
}

case "${1:-}" in
  on)
    agent="${2:-}"; lp="${3:-}"; ba="${4:-}"; mp="${5:-}"; yolo="${6:-0}"; ssh_config="${7:-}"
    case "$agent" in claude|codex|opencode) ;; *) echo "RH_STATUS=ERROR"; exit 2;; esac
    [ -n "$lp" ] && [ -n "$ba" ] || { echo "RH_STATUS=ERROR"; exit 2; }
    SD="$(session_dir "$mp")"
    rm -rf "$SD" 2>/dev/null || true
    mkdir -p "$SD" 2>/dev/null || { echo "RH_STATUS=ERROR"; exit 1; }
    RULE="$SD/rule.md"
    write_rule "$RULE" "$lp" "$ba" "$mp" || { echo "RH_STATUS=ERROR"; exit 1; }

    env_out=""; flags_out=""
    if [ -n "$ssh_config" ]; then
      if write_ssh_wrapper "$SD" "$ba" "$ssh_config"; then
        env_out="PATH=$(sq "$SD/bin"):\$PATH"
      fi
    fi
    case "$agent" in
      claude)
        flags_out="--append-system-prompt-file $(sq "$RULE")"
        ;;
      opencode)
        # OPENCODE_CONFIG is merged ADDITIVELY on top of the user's global + project configs, so we
        # only write a minimal session layer (instructions + permission on yolo). No jq, no copying
        # the user's config — that avoided a crash on a non-array `instructions` and a stale config
        # snapshot overriding a project-local opencode.json.
        CFG="$SD/opencode.json"
        [ "$yolo" = 1 ] && perm='"permission": "allow", ' || perm=''
        # JSON-escape the rule path: escape \ then " (both legal in Unix paths; rare but correct).
        rule_json="$(printf '%s' "$RULE" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        printf '{ "$schema": "https://opencode.ai/config.json", %s"instructions": ["%s"] }\n' "$perm" "$rule_json" > "$CFG"
        env_out="${env_out:+$env_out }OPENCODE_CONFIG=$(sq "$CFG")"
        ;;
      codex)
        dev_cfg="developer_instructions=$(toml_basic_string_file "$RULE")"
        flags_out="-c $(sq "$dev_cfg")"
        # codex's default sandbox gates network, which blocks the rule's `ssh <host> ...`. The
        # `[sandbox_workspace_write]` sub-table only merges when workspace-write is EXPLICITLY
        # selected, so `-s workspace-write` is required — `network_access` alone at the implicit
        # default is IGNORED. Under --yolo, --dangerously-bypass-approvals-and-sandbox already drops
        # the sandbox entirely, so DON'T add -s there (it would conflict).
        # workspace-write needs explicit network access for the rule's `ssh <host> ...`, plus write
        # access to the session-owned directories where the wrapper/config put temporary known_hosts.
        # Do not add ~/.ssh; user SSH files remain read-only/user-managed.
        if [ "$yolo" != 1 ]; then
          roots_cfg="$(codex_writable_roots_cfg "$SD" "$ssh_config")"
          flags_out="$flags_out -s workspace-write -c sandbox_workspace_write.network_access=true -c $(sq "$roots_cfg")"
        fi
        ;;
    esac
    printf 'RH_STATUS=INJECTED\n'
    printf 'RH_LAUNCH_ENV=%s\n'   "$env_out"
    printf 'RH_LAUNCH_FLAGS=%s\n' "$flags_out"
    ;;
  off)
    mp="${3:-}"; SD="$(session_dir "$mp")"
    # All agents' artifacts (the rule file, and for opencode its session config) live in the session
    # dir; none of them touched the mounted repo — so cleanup is just removing that dir.
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
