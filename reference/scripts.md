# Helper scripts (reference)

All scripts live in `$RH/scripts/` where `RH="${RH_HOME:-$HOME/.remote-harness}"`. They print
`KEY=VALUE` on stdout (parse that); human notes go to stderr.

```bash
RH="${RH_HOME:-$HOME/.remote-harness}"
[ -d "$RH/scripts" ] || echo "scripts missing — run: manage.sh"
```

- `"$RH/scripts/preflight.sh"` — **legacy/diagnostic only**. Current simple reverse/forward does not
  call it; the mode-specific setup scripts create session-local SSH configs and run targeted checks
  themselves. It still emits `PREFLIGHT=ok|blocked` + `BLOCKED_STEP`/`ERROR`/`REMEDY` + `DIRECTION`
  for old runbooks or focused debugging. Reverse checks only an explicit `--alias` or historical
  loopback aliases visible through `~/.ssh/config`; it does not understand a fresh simple session
  unless that session alias is supplied. Forward: `--direction forward [--server '<via>']` checks local
  sshfs/FUSE (+ server reachability). It does NOT scan for the user's project.
- `"$RH/scripts/simple-bootstrap.sh"` — **public unified simple entry point, run on the LOCAL
  machine**. When it is run from a local install, it delegates directly to `simple-dispatch.sh`.
  When it is piped from a remote skill/source install, it uses `--via`/`RH_VIA` to fetch
  `_common.sh`, `simple-dispatch.sh`, both simple wizards, and their local dependencies into a temp
  dir, then delegates to that fetched dispatcher. Pass `--mode reverse`, `--mode forward`, or omit
  `--mode` for local mode selection. Keep the skill command compact but copyable: use a small number
  of short lines and keep any remote `ssh ... | bash ...` pipeline on readable continuation lines. It
  records the script-source `LAST_VIA` in local `~/.remote-harness/simple-cache.env`.
- `"$RH/scripts/suggest-via.sh"` — **simple reverse remote-side SSH target default helper**. It runs
  on the remote box before the agent answers and emits `STATUS`, `VIA`, and `SOURCE`. It may use the
  remote username, server address, and server SSH port. If it reads `SSH_CONNECTION`, it uses only
  fields 3 and 4 (`server-ip` / `server-port`) and never emits fields 1 and 2, which are local/client
  data. The `VIA` value is only an editable prompt default; local `LAST_VIA` cache wins.
- `"$RH/scripts/simple-laptop-setup.sh"` — **simple reverse local wizard**. It prompts locally for the
  laptop project dir, optional remote mountpoint, and launch preference. It uses the fixed session
  alias `rlocal`, writes that alias only to a remote temp ssh config via
  `setup-tunnel.sh --config <temp-config> --namespace rlocal --alias rlocal --gen-key`, then invokes
  `laptop-setup.sh` with `--box-ssh-config`, `--project-dir`, `--box-alias`, `--port`, and the
  selected `--launch` value. The generated remote-harness public key is handed to `laptop-setup.sh`
  for scoped temporary authorization. It saves the confirmed defaults into the same local cache file
  for future runs.
- `"$RH/scripts/simple-local-setup.sh"` — **simple forward local wizard**. It prompts locally for the
  server SSH target, server project directory, optional local mountpoint, and launch preference. It
  saves confirmed defaults in `~/.remote-harness/simple-forward-cache.env`, then invokes
  `local-setup.sh`. The launched agent edits/searches files in the local mount while project
  commands run on the server through the injected SSH rule.
- `"$RH/scripts/simple-dispatch.sh"` — **simple local mode dispatcher**. It accepts explicit
  `--mode reverse|forward`; when `--mode` is omitted, it prompts locally, defaults to reverse on
  first run, caches `LAST_MODE` in `~/.remote-harness/simple-mode-cache.env`, then hands off to
  `simple-laptop-setup.sh` or `simple-local-setup.sh`. The private `--source-via` argument is passed
  by `simple-bootstrap.sh` and is reused only for reverse mode.
- `"$RH/scripts/detect.sh"` — **legacy/compatibility read-only probe**. The simple path no longer asks
  the agent to infer namespaces; `setup-tunnel.sh --namespace` owns the stable port derivation. This
  script remains for tests and old diagnostics: `REALUSER_GUESS`/`REALUSER_SOURCE`
  (`authkey|cwd|authorized_keys|none`)/`REALUSER_CANDIDATES` (the per-real-user namespace guess on a
  shared box account — confirm before use), `SUGGESTED_PORT` (hashed from `REALUSER_GUESS` to a
  stable `.22` slot so different users don't collide; old "highest free `.22`" fallback when no namespace),
  `LAPTOP_USER_GUESS`, `DEFAULT_IDENTITY`, `SSHD_TCP_FORWARDING`, `ON_REMOTE`. It must not emit local
  client IP/port values.
- `"$RH/scripts/setup-tunnel.sh"` — (reverse) write the box-side `ssh` alias to a **session-local
  config only** (`--config <absolute-path>` is required). Emits `ALIAS`, `PORT`, `CONFIG`, `PUBKEY`,
  `REMOTEFORWARD_LINE`, and a `KNOWN_HOSTS` path next to that session config. It never writes
  anything under `~/.ssh`.
  Give EITHER `--port <PORT>` OR `--namespace <RU>`: with `--namespace` (and no `--port`) it derives
  the stable port from `RU` the same way `detect.sh` does and probes for a free slot. Manual
  `--gen-key` creates an ed25519 key under `$RH_HOME/keys` so `PUBKEY` is non-empty; simple reverse
  requests this automatically so the laptop can add a scoped temporary `authorized_keys` entry.
- `"$RH/scripts/connect-guesses.sh"` — **legacy/opt-in** reverse SSH-target guessing helper. The
  current simple path uses `suggest-via.sh` for a narrow server-side default instead.
- `"$RH/scripts/check-tunnel.sh"` — (reverse) verify listener + real ssh login through the tunnel
  (`--port <PORT>` to check a specific forwarded port).
- `"$RH/scripts/server-guesses.sh"` — **opt-in only** forward SSH-target suggestion helper. The default
  simple forward wizard asks the user for the server target and uses the local cache as the default;
  it does not scan `~/.ssh/config`, `known_hosts`, or shell history unless a user explicitly asks for
  suggestions.
- `"$RH/scripts/list-projects.sh"` — list candidate project dirs locally, or on a remote via
  `--via '<ssh-args|alias>'`. **Opt-in only** — the default flow does NOT scan for the user's project
  (slow + misleading; see SKILL.md "ask, don't fish"); the user types the path. Use this only if the
  user explicitly asks for help finding it. `PROJECT\t<path>…`.
- `"$RH/scripts/session-cache.sh"` — **legacy generic cache helper**. Current simple scripts use
  dedicated local cache files (`simple-cache.env`, `simple-forward-cache.env`, and
  `simple-mode-cache.env`) so the user sees defaults in the terminal wizard without involving the
  agent. Keep this helper only for old integrations or explicit tooling.
- `"$RH/scripts/mount-project.sh"` — sshfs-mount `<alias>:<remote-path>` onto a LOCAL mountpoint
  (direction-agnostic). Refuses a non-empty target (`--force` to override); revalidates/remounts a
  stale mount; `--unmount` to detach. Emits
  `STATUS=mounted|already-mounted|need-sshfs|not-empty|failed|unmounted`.
- `"$RH/scripts/local-setup.sh"` — **(forward) runs on the LOCAL machine**: resolves a stable ssh
  alias to the server through a session-local ssh config (a session-local alias from `--via` if raw),
  sshfs-mounts the server's project locally, injects the run-on-server rule, and launches the agent
  locally in the mount; unmounts on exit and removes the temp config. It does not write local
  `~/.ssh`.
  Args: `--via '<ssh-args|alias>' --remote-path '<dir>' [--mountpoint '<dir>'] --launch <cli> [--yolo]`.
- `"$RH/scripts/laptop-setup.sh"` — **(reverse) runs on the LAPTOP**: Phases 1-5 fully automated.
  Phase 1: SSH server check and a **session-local** RemoteForward config under local
  `~/.remote-harness/.sessions/.../ssh_config`. Phase 2: reconnect through an internal ssh wrapper.
  Phase 3: validate project dir (`--project-dir` supplies the confirmed default; invalid paths prompt
  again). Phase 4: sshfs mount on remote (retries interactively on sshfs-missing / non-empty).
  Phase 5: inject the run-on-laptop rule, then launch the chosen agent (`--launch`, default
  `claude`). Full sessions require `--box-ssh-config`; `--setup-only` may omit it. It does not write
  local `~/.ssh/config`, `known_hosts`, or SSH keys. In full reverse sessions, when `--pubkey` is
  present, it may add a tagged `remote-harness:reverse-auth:<tag>` block to local
  `~/.ssh/authorized_keys`, restricted to loopback and reference-counted for cleanup.
- `"$RH/scripts/inject-rule.sh"` — **runs where the agent runs** (the box in reverse, the local
  machine in forward), direction-NEUTRAL:
  `on <agent> <code_path> <host_alias> <mountpoint> [yolo]` builds **per-session** artifacts under
  `$RH_HOME/.sessions/<key>` and prints how to launch so ONLY this session reads the rule —
  **nothing global, nothing in the mounted repo**. It prints `RH_STATUS`, `RH_LAUNCH_ENV`,
  `RH_LAUNCH_FLAGS`:
    - claude   → `RH_LAUNCH_FLAGS=--append-system-prompt-file '<rule>'` (session flag)
    - opencode → `RH_LAUNCH_ENV=OPENCODE_CONFIG='<session cfg>'` (instructions; +`permission:"allow"` if yolo)
    - codex    → `RH_LAUNCH_FLAGS=-c 'developer_instructions="<rule>"'` (session-only CLI config;
      leaves the real `CODEX_HOME` in place so keyring-backed ChatGPT auth still works). Non-yolo also gets
      `-s workspace-write -c sandbox_workspace_write.network_access=true` plus writable roots for the
      relevant `~/.remote-harness/.sessions/...` dirs so the sandbox permits outbound ssh and lets ssh
      write temporary ControlPath/known_hosts there. It never makes `~/.ssh` writable. `-s` is required;
      the sub-table is ignored at the implicit default. For heavy/long codex sessions `$remote-harness yolo`
      (drops the sandbox) is still simplest.)
  The rule says the cwd is an sshfs mount of `<code_path>` on `<host_alias>` and to run
  builds/tests/linters/installs/the app **on `<host_alias>`** via `ssh <host_alias> 'cd <code_path>
  && <cmd>'` (never on "this machine"), with **stack-tailored example commands** sniffed from the
  manifests. Both setup scripts splice `RH_LAUNCH_ENV`/`RH_LAUNCH_FLAGS` into the launch and call
  `off <agent> <mountpoint>` (removes the session dir) on exit.
- `"$RH/scripts/_common.sh"` — shared helpers sourced by both setup scripts (colors, `ask`, `sq`,
  `parse_via`, `write_managed_alias`, OS vars). `parse_via` preserves user/port/identity and
  `ProxyJump` (`-J` / `-o ProxyJump=...`) when a setup script writes a managed ssh alias. It
  deliberately rejects unsupported raw SSH semantics (`ProxyCommand`, `-F`, local forwards, quoted
  tokens with spaces): users should put those in `~/.ssh/config` as a `Host` alias and pass the
  alias. Not an entry point.
