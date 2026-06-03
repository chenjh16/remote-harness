# Helper scripts (reference)

All scripts live in `$RH/scripts/` where `RH="${RH_HOME:-$HOME/.remote-harness}"`. They print
`KEY=VALUE` on stdout (parse that); human notes go to stderr.

```bash
RH="${RH_HOME:-$HOME/.remote-harness}"
[ -d "$RH/scripts" ] || echo "scripts missing — run: manage.sh"
```

- `"$RH/scripts/preflight.sh"` — one-shot check; emits `PREFLIGHT=ok|blocked` + `BLOCKED_STEP`/
  `ERROR`/`REMEDY` + `DIRECTION`. Reverse (default): checks the tunnel + local sshfs/FUSE. Pass
  `--alias <RU>-mac` to reuse ONLY that real user's namespaced tunnel (on a shared box account,
  without it preflight would scan every loopback alias and could latch onto another user's tunnel).
  Forward: `--direction forward [--server '<via>']` checks local sshfs/FUSE (+ server reachability).
  It does NOT scan for the user's project (the flow asks the user to type the path; the legacy
  `--no-list` flag is now a no-op). Run this first.
- `"$RH/scripts/detect.sh"` — read-only probe: `REALUSER_GUESS`/`REALUSER_SOURCE`
  (`authkey|cwd|authorized_keys|none`)/`REALUSER_CANDIDATES` (the per-real-user namespace guess on a
  shared box account — confirm before use), `SUGGESTED_PORT` (hashed from `REALUSER_GUESS` to a
  stable `.22` slot so different users don't collide; legacy "highest free `.22`" when no namespace),
  `LAPTOP_USER_GUESS`, `DEFAULT_IDENTITY`, `SSHD_TCP_FORWARDING`, `ON_REMOTE`. Used when building the
  tunnel.
- `"$RH/scripts/setup-tunnel.sh"` — (reverse) write the box-side `ssh` alias
  (`<RU>-mac → 127.0.0.1:PORT`). Emits `ALIAS`, `PORT`, `PUBKEY`, `REMOTEFORWARD_LINE`. Idempotent;
  the shared `~/.ssh/config` edit is `flock`-serialized so concurrent runs on a shared account don't
  clobber each other. Give EITHER `--port <PORT>` OR `--namespace <RU>`: with `--namespace` (and no
  `--port`) it derives the stable port from `RU` the same way `detect.sh` does and probes for a free
  slot — pass the confirmed `RU` so the port follows it, not the pre-confirmation guess. Pass
  `--gen-key` when the box has no SSH key (empty `DEFAULT_IDENTITY`) so it creates an ed25519 key and
  `PUBKEY` is non-empty.
- `"$RH/scripts/connect-guesses.sh"` — (reverse) guess how the laptop reaches this box.
- `"$RH/scripts/check-tunnel.sh"` — (reverse) verify listener + real ssh login through the tunnel
  (`--port <PORT>` to check a specific forwarded port).
- `"$RH/scripts/server-guesses.sh"` — (forward) suggest OUTBOUND ssh targets (the project server)
  from `~/.ssh/config` non-loopback aliases, known_hosts, and recent history. Prints `ssh <target>`
  lines. The user's own answer is authoritative.
- `"$RH/scripts/list-projects.sh"` — list candidate project dirs locally, or on a remote via
  `--via '<ssh-args|alias>'`. **Opt-in only** — the default flow does NOT scan for the user's project
  (slow + misleading; see SKILL.md "ask, don't fish"); the user types the path. Use this only if the
  user explicitly asks for help finding it. `PROJECT\t<path>…`.
- `"$RH/scripts/session-cache.sh"` — remember a namespace's last connection choices on THIS machine so
  a re-run recommends them instantly (zero remote discovery). `put <key> KEY=VALUE…` stores;
  `get <key>` prints the stored `KEY=VALUE` lines (none if absent). Per-namespace file under
  `$RH_HOME/.sessions-cache/<key>.env` (mode 600). Key by the real-user `RU` (reverse) or the server
  token (forward); the flows cache `LAST_PROJECT_DIR`/`LAST_VIA`/`LAST_MOUNTPOINT`/
  `LAST_LAUNCH` and pre-fill the next run's questions from them.
- `"$RH/scripts/mount-project.sh"` — sshfs-mount `<alias>:<remote-path>` onto a LOCAL mountpoint
  (direction-agnostic). Refuses a non-empty target (`--force` to override); revalidates/remounts a
  stale mount; `--unmount` to detach. Emits
  `STATUS=mounted|already-mounted|need-sshfs|not-empty|failed|unmounted`.
- `"$RH/scripts/local-setup.sh"` — **(forward) runs on the LOCAL machine**: resolves a stable ssh
  alias to the server (managed alias from `--via` if raw), sshfs-mounts the server's project locally,
  injects the run-on-server rule, and launches the agent locally in the mount; unmounts on exit.
  Args: `--via '<ssh-args|alias>' --remote-path '<dir>' [--mountpoint '<dir>'] --launch <cli> [--yolo]`.
- `"$RH/scripts/laptop-setup.sh"` — **(reverse) runs on the LAPTOP**: Phases 1-5 fully automated.
  Phase 1: SSH server, authorized key, RemoteForward config. Phase 2: reconnect. Phase 3: validate
  project dir (`--project-dir` supplies the confirmed default; invalid paths prompt again). Phase 4: sshfs mount on remote (retries
  interactively on sshfs-missing / non-empty). Phase 5: inject the run-on-laptop rule, then launch
  the chosen agent (`--launch`, default `claude`).
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
      `-s workspace-write -c sandbox_workspace_write.network_access=true
      -c 'sandbox_workspace_write.writable_roots=["~/.ssh"]'` so the sandbox permits the rule's outbound ssh
      AND lets ssh write its ControlMaster socket / known_hosts under `~/.ssh` — `-s` is required, the
      sub-table is ignored at the implicit default. For heavy/long codex sessions `$remote-harness yolo`
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
