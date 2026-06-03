# remote-harness — design

> Chinese counterpart: [design.cn.md](design.cn.md). This document explains *how the project is built
> and why*. User-facing docs: [`../README.md`](../README.md). Runtime skill spec: [`../SKILL.md`](../SKILL.md).
> Dev guide: [`../AGENTS.md`](../AGENTS.md).

## 1. What problem it solves

A coding agent (Claude Code / Codex / opencode) and the codebase it works on frequently live on
**two different machines**. remote-harness connects them so the agent edits the code as if it were
local, while builds/tests run on the machine that actually hosts the code. It does this in **either
direction** and hands the user **one copy-paste command** that performs the mount + launch.

The guiding constraints:

- **Zero runtime dependencies** beyond `ssh` + `sshfs` (everything else is POSIX shell).
- **No persistent footprint**: mounts, tunnels, and injected rules are torn down on exit; nothing
  global is written and the mounted repo is never modified.
- **Agent-driven but never silent**: the agent runs a continuous flow but must *confirm* every
  consequential choice with the user.

## 2. The core model — two directions, one invariant

Two generic roles:

- **A** = the machine the **agent** runs on.
- **P** = the machine the **project/code** lives on, referenced by an ssh `<alias>`.

```
                 reverse                                   forward
   A = remote box            P = laptop          A = local machine     P = remote server
   (agent here)          (code here, NAT'd)       (agent here)          (code here)
        │  reverse SSH tunnel  ▲                       │  direct ssh        ▲
        ▼  (laptop dials out)  │                       ▼                    │
   sshfs mount  ◀── laptop project                sshfs mount ◀── server project
```

- **reverse** — A is a remote box, P is the user's laptop behind NAT. The box can't dial the laptop,
  so the laptop opens a **reverse SSH tunnel** (`RemoteForward <port> 127.0.0.1:22`) and the box
  sshfs-mounts the laptop project back over that tunnel. Orchestrated by `laptop-setup.sh` running on
  the laptop.
- **forward** — A is the local machine, P is a directly ssh-reachable server. No tunnel; the local
  machine sshfs-mounts the server's project directly. Orchestrated by `local-setup.sh` running
  locally.

Both directions share the **same invariant**:

> sshfs-mount P's project onto an **empty** dir on A → inject a rule that builds/tests run **on P**
> (`ssh <alias> 'cd <path> && …'`) → launch the agent in the mount.

The empty-dir requirement is structural: sshfs hides whatever is already in the mountpoint, and the
remote project must cleanly become the project root.

## 3. Layered architecture

remote-harness is deliberately split into four layers, from "what the agent reads" down to "what
actually runs". This is the key design decision that keeps the agent prompt small and the behavior
deterministic.

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1. Skill spec      SKILL.md  (+ reference/{reverse,forward,scripts}.md)│  ← the agent reads this
│    progressive disclosure: lean entry → per-direction flow on demand   │
├──────────────────────────────────────────────────────────────────────┤
│ 2. Orchestrators   laptop-setup.sh (reverse) · local-setup.sh (forward)│  ← the ONE emitted command
│    self-contained, interactive, run on the user's side                 │
├──────────────────────────────────────────────────────────────────────┤
│ 3. Helper scripts  detect/preflight/setup-tunnel/check-tunnel/mount-…  │  ← deterministic units
│    one responsibility each, KEY=VALUE on stdout, notes on stderr       │
├──────────────────────────────────────────────────────────────────────┤
│ 4. Shared library  _common.sh  (sourced, never executed)              │  ← colors/quoting/ssh-config
└──────────────────────────────────────────────────────────────────────┘
   Agent adapters (claude/codex/opencode) + manage.sh install all point at layer 1.
```

### Layer 1 — the skill spec (progressive disclosure)

`SKILL.md` is the lean entry point: what the skill does, the interaction rules, and direction
selection. Per-direction depth lives under `reference/` and is read **on demand** at runtime:

- `reference/reverse.md` — the full reverse flow (identify user → build tunnel → emit laptop command).
- `reference/forward.md` — the full forward flow (pick server/dir → emit local command).
- `reference/scripts.md` — the helper-script `KEY=VALUE` contracts.

Every doc has a Chinese `*.cn.md` counterpart (Chinese is the primary audience); `README.md` is
inline-bilingual and `CLAUDE.md` is a symlink, so those two are exempt.

### Layer 2 — the orchestrators

The agent never mounts anything itself. It assembles **one command** that the user pastes on the
machine that holds the code-side credentials, and that command runs a self-contained orchestrator:

- **`laptop-setup.sh`** (reverse, runs on the laptop) — Phases 1-5 (below). It must run
  **standalone**: the laptop usually has no install, so the emitted command fetches both
  `laptop-setup.sh` *and* `_common.sh` into one temp dir (`laptop-setup.sh` sources `_common.sh` from
  beside it). This standalone-ness is a hard invariant — nothing it needs may live only in the
  install dir.
- **`local-setup.sh`** (forward, runs locally) — resolve a stable ssh alias to the server, mount,
  inject the rule, launch the agent locally, unmount on exit.

### Layer 3 — the helper scripts (the KEY=VALUE contract)

Each script has **one responsibility** and follows a strict I/O contract: **`KEY=VALUE` lines on
stdout** (machine-parseable by the agent), **human notes on stderr**. This lets the agent parse
results reliably without brittle natural-language scraping.

| script | dir | responsibility | key outputs |
|---|---|---|---|
| `detect.sh` | reverse | read-only environment probe | `REALUSER_GUESS/SOURCE/CANDIDATES`, `SUGGESTED_PORT`, `DEFAULT_IDENTITY`, `SSHD_TCP_FORWARDING`, `ON_REMOTE` |
| `preflight.sh` | both | one-shot gate (replaces several round-trips) | `PREFLIGHT=ok\|blocked`, `BLOCKED_STEP`/`ERROR`/`REMEDY`, `TUNNEL_ALIAS/PORT`, `PROJECT_DIR_EMPTY` |
| `setup-tunnel.sh` | reverse | write the box-side `<RU>-mac` alias + derive the port | `ALIAS`, `PORT`, `PUBKEY`, `REMOTEFORWARD_LINE` |
| `connect-guesses.sh` | reverse | guess how the laptop reaches the box | `ssh user@ip` lines |
| `server-guesses.sh` | forward | guess outbound ssh targets (the server) | `ssh <target>` lines |
| `check-tunnel.sh` | reverse | verify listener + a real login through the tunnel | `SSH=up\|down`, `LAPTOP_HOSTNAME/USER` |
| `mount-project.sh` | both | sshfs mount/unmount onto a local path | `STATUS=mounted\|already-mounted\|need-sshfs\|not-empty\|failed\|unmounted` |
| `list-projects.sh` | both | enumerate candidate project dirs (locally or `--via`) | `PROJECT\t<path>\tgit:<branch>` |
| `inject-rule.sh` | both | per-session "build on P" rule + per-agent launch flags | `RH_STATUS`, `RH_LAUNCH_ENV`, `RH_LAUNCH_FLAGS` |

### Layer 4 — the shared library

`_common.sh` is **sourced, never executed**. It provides colors + output helpers (`say/ok/warn/err/
hdr`), the interactive `ask` (honoring `ASSUME_YES`), OS detection (`OS/PLAT/IS_WSL`), and the two
pieces that matter most for safety:

- **`sq()`** — shell-quote a value for safe interpolation into a remote command string. Every value
  spliced into an ssh command goes through `sq()`; paths may legally contain apostrophes (macOS), and
  unquoted interpolation is an injection/break risk.
- **`parse_via()` + `write_managed_alias()`** — parse a raw ssh connect string (`-J jump -p 2222
  user@host -i key`) into fields and write an idempotent managed `Host` block to `~/.ssh/config`. The
  connect string is intentionally word-split, **never `eval`'d**, so a crafted/mistyped string can't
  execute locally. Complex ssh semantics (`ProxyCommand`, `-F`, spaces) are rejected with a "put it
  in `~/.ssh/config` as a Host alias" message.

## 4. The reverse flow in detail

`laptop-setup.sh` automates five phases on the laptop:

1. **Phase 1 — SSH server + key + config.** Ensure sshd is running, add the box's public key to
   `~/.ssh/authorized_keys`, and write a **dedicated** managed alias `<host>-remote-harness` carrying
   `RemoteForward <port> 127.0.0.1:22` + keepalives + `ExitOnForwardFailure yes`. It is *dedicated*
   (not the user's normal alias) so ordinary `ssh <host>` never inherits the RemoteForward and fails
   while a tunnel already owns the port.
2. **Phase 2 — Reconnect → tunnel up.** Open `ssh -N <host>-remote-harness`, poll until the box's
   loopback port is listening. Before trusting an existing listener it **verifies ownership**
   (hostname + user via `check-tunnel.sh`): if the port is owned by another/stale tunnel it scans the
   next 200 ports, rewrites the laptop RemoteForward *and* the box-side alias, and continues on the
   first free port.
3. **Phase 3 — Pick the laptop project dir** (readline prompt; `--project-dir` supplies a confirmed
   default and the script re-prompts on an invalid path).
4. **Phase 4 — Mount on the box** by ssh-ing to the box and running `mount-project.sh` over the
   tunnel (interactive retry on sshfs-missing / non-empty).
5. **Phase 5 — Inject the rule + launch** via `inject-rule.sh on …` then `ssh -t` into a
   login+interactive shell so PATH (e.g. `~/.local/bin`) resolves the agent CLI.

A trap installs **auto-cleanup**: on exit it unmounts the box mountpoint, removes the session rule,
and drops the tunnel.

### Two distinct ssh aliases (a subtle but important point)

| alias | lives in | direction | written by | carries |
|---|---|---|---|---|
| `<RU>-mac` | the **box**'s `~/.ssh/config` | box → laptop | `setup-tunnel.sh` | `HostName 127.0.0.1`, `Port <rport>`, the laptop login user/key |
| `<host>-remote-harness` | the **laptop**'s `~/.ssh/config` | laptop → box | `laptop-setup.sh` | the real connect params **plus** `RemoteForward <rport> 127.0.0.1:22` |

The box reaches the laptop with `ssh <RU>-mac` (that is what the injected rule uses); the laptop
reaches the box — and *establishes* the tunnel — with `ssh <host>-remote-harness`.

## 5. The forward flow in detail

`local-setup.sh` runs locally and is simpler (no tunnel):

1. Resolve the server connection from `--via`. A raw connect string (explicit user/port/key/jump) is
   persisted as a managed `<host>-dev` alias; a bare alias/host is used as-is.
2. sshfs-mount `<alias>:<remote-path>` onto a local empty dir (default
   `~/remote-harness-mounts/<name>`), with the same interactive retry as reverse.
3. Inject the run-on-server rule (`inject-rule.sh`), then launch the agent **locally** in the mount
   (subshell + `exec` so the cleanup trap still fires; guarded to bash/zsh because the env-prefix
   `VAR=val` form is unsupported by fish/csh).
4. Unmount on exit.

forward is essentially immune to the shared-account conflicts that reverse has to solve (§7), because
each user runs the agent on their own machine and writes their own `~/.ssh/config`.

## 6. Session-scoped rule injection (per agent)

The agent works in an sshfs mount but the host machine may lack the project's toolchain. Running
`npm install` / `cargo build` / a linter / a language server there would pollute the mount with
wrong-OS/arch artifacts and silently corrupt the code host. `inject-rule.sh` therefore injects a rule
— "run every build/test/lint/install and `git commit`/`push` on `<alias>`, never here" — with
**stack-tailored example commands** sniffed from the project's manifests.

Crucially the rule is **session-scoped**: artifacts live under `$RH_HOME/.sessions/<key>` (key derived
from the mountpoint), nothing global is written, and the mounted repo is never touched. Each agent
gets the cleanest scoped channel it supports:

- **claude** → `--append-system-prompt-file <rule>` (a session-only flag).
- **opencode** → `OPENCODE_CONFIG=<session config>` (env; `instructions` + `permission:"allow"` under
  yolo), merged additively over the user's config.
- **codex** → `-c developer_instructions=<rule>` (session-only CLI config, leaving the real
  `CODEX_HOME` intact so keyring-backed auth still works). Non-yolo also adds `-s workspace-write` +
  `network_access=true` + `writable_roots=["~/.ssh"]` so codex's sandbox permits the rule's outbound
  ssh and ssh's own `~/.ssh` writes.

`off` simply removes the session dir on exit.

## 7. Multi-user namespacing on a shared box account (reverse)

When one box account is shared by several real users, all box-side state lives under one `$HOME`, so
their reverse tunnels can collide — and the box-side alias can get cross-wired so one user's
builds/commits run against another user's laptop. The fix (see [`../issues/issue1.md`](../issues/issue1.md)
for the full analysis) is a confirmed **per-real-user namespace `RU`**:

- `detect.sh` guesses `RU` from (in priority order) the session's authenticating public-key **full**
  comment (read from the `$SSH_USER_AUTH` file sshd writes under `ExposeAuthInfo yes`; the local part
  is offered as a friendlier candidate), the first `~/<name>/…` launch-dir component, or an
  authorized_keys comment — then the agent **confirms** it (a fourth "Confirm, don't infer" value).
- The box-side alias becomes `<RU>-mac`, and the reverse port is **hashed stably from `RU`** to a
  `.22` slot in `[20022, 29922]` below the ephemeral floor (so different users land on different
  ports, and the same user reconnects to the same port — enabling **one-tunnel / many-projects**
  reuse). `setup-tunnel.sh` derives this from `--namespace`; `preflight.sh --alias <RU>-mac` reuses
  *only* that user's tunnel.
- The shared `~/.ssh/config` edit is `flock`-serialized so concurrent setups don't clobber each
  other's managed block.

The rule is: **port + alias are per-real-user (stable); mountpoint + session are per-project.**

## 8. Cross-cutting invariants

These hold across the whole codebase and are enforced in review/tests:

1. **Confirm, don't infer.** Direction, the code location, the mountpoint, and (reverse, shared
   account) the namespace `RU` are each an explicit user choice — detection only *pre-fills*.
2. **`laptop-setup.sh` stays standalone** (fetched to an install-less laptop; sources `_common.sh`
   from beside it).
3. **`inject-rule.sh` is direction-neutral and never writes the mounted repo.**
4. **Shell-quote every value spliced into a remote command** with `sq()`; never `eval` `--via`.
5. **Portability** — target Linux, WSL, macOS. `#!/usr/bin/env bash`; avoid GNU-only flags; listener
   checks go `ss → netstat -an → lsof`; macOS uses **FUSE-T** (no kernel extension), never macFUSE;
   `set -uo pipefail` (not `-e`) on probes that must keep emitting.
6. **`KEY=VALUE` on stdout, human notes on stderr** — the parsing contract.
7. **Bilingual docs** — every `*.md` ships a `*.cn.md` (except `README.md`, `CLAUDE.md`).

## 9. Lifecycle, idempotency & cleanup

- **Idempotent** — re-running remote-harness re-uses a live tunnel and a correct existing mount;
  managed ssh blocks are create-or-replace; ssh config is backed up before edits.
- **Stale-mount detection** — `mount-project.sh` checks a mount is actually *alive* (not a dead sshfs
  endpoint from a dropped tunnel) and remounts fresh otherwise.
- **Auto-teardown** — both orchestrators install an exit trap that unmounts and removes the session
  rule. In reverse the tunnel is **refcounted**: it is dropped only when no other session's mount
  still rides it, and the last session out tears it down via a pid file — so same-user multi-project
  sessions can exit in any order without stranding each other's mounts. `manage.sh --uninstall` never
  touches your ssh tunnel config or mounts.

## 10. Installation & distribution

`manage.sh` installs the shared core to `~/.remote-harness/{SKILL.md, scripts/, reference/}` plus a
per-agent entry: Claude Code and Codex both get the native skill (`SKILL.md`), opencode gets a custom
command. `--dev` symlinks to the repo (edits go live); `--uninstall` removes the entries. It hard-
guards `RH_HOME` (must be absolute, end in `remote-harness`, never `/` or `$HOME`) before any `rm`.

## 11. Testing

- `bash -n scripts/*.sh manage.sh tests/regression.sh` — the syntax gate, run after every change.
- `tests/regression.sh` — a hermetic suite covering `parse_via`/managed-alias writing, project
  scanning + quoting, per-agent rule injection, the reverse port-conflict fallback, the tunnel-reuse
  path, `RU`/namespace derivation + stable-port sync, launch validation, `manage.sh` `RH_HOME`
  guards, and the **bilingual-doc pairing** check (every `*.md` has a `.cn.md`).
- `tests/codex_tui_e2e.py` — a live (non-hermetic) pexpect smoke test that drives the Codex TUI
  through the skill to verify structured `request_user_input` prompts.

## 12. File map

```
remote-harness/
├── SKILL.md / SKILL.cn.md       # layer 1: lean skill entry
├── reference/                   # layer 1: progressive-disclosure depth
│   ├── reverse.md  forward.md   # per-direction flows
│   └── scripts.md               # KEY=VALUE contracts (+ .cn.md each)
├── scripts/                     # layers 2-4
│   ├── _common.sh               # layer 4: sourced library
│   ├── preflight.sh detect.sh setup-tunnel.sh check-tunnel.sh connect-guesses.sh   # reverse probes
│   ├── server-guesses.sh        # forward probe
│   ├── laptop-setup.sh          # layer 2: reverse orchestrator (standalone)
│   ├── local-setup.sh           # layer 2: forward orchestrator
│   └── mount-project.sh inject-rule.sh list-projects.sh   # shared by both
├── adapters/{codex,opencode}.md # agent entry notes (set --launch)
├── manage.sh                    # install / --dev / --uninstall
├── docs/design.md               # this document (+ .cn.md)
├── issues/issue1.md             # the shared-account namespacing analysis (+ .cn.md)
├── tests/regression.sh codex_tui_e2e.py
├── AGENTS.md (+ CLAUDE.md symlink)   # dev guide for agents working ON this repo
└── README.md                    # user-facing, inline-bilingual
```
