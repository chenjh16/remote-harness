# AGENTS.md — guide for coding agents working ON this repo

This repo is the **remote-harness** skill: it connects a coding agent and a codebase that live on
two different machines, in either direction, and hands the user one copy-paste command to mount the
code + launch the agent. (User-facing docs: `README.md`. Runtime skill spec: `SKILL.md`.) This file
is for agents *developing* remote-harness itself.

> A `CLAUDE.md` symlink points here so Claude Code loads it; Codex/opencode read `AGENTS.md` natively.

## Repo layout

- `SKILL.md` — lean skill entry point (overview, interaction rules, direction pick). **Progressive
  disclosure**: per-direction flow + script contracts live under `reference/`.
- `reference/{reverse,forward,scripts}.md` — the detailed flows and helper-script contracts, read on
  demand by the agent at runtime via `$RH/reference/<file>.md` (`RH=${RH_HOME:-$HOME/.remote-harness}`).
- `scripts/*.sh` — the deterministic helpers (KEY=VALUE on stdout, notes on stderr). `_common.sh` is
  a sourced library (not an entry point). `laptop-setup.sh` (reverse) / `local-setup.sh` (forward)
  are the orchestrators; `mount-project.sh` + `inject-rule.sh` + `list-projects.sh` are reused by both.
- `adapters/{codex,opencode}.md` — per-agent notes. `opencode.md` is installed as opencode's custom
  command; `codex.md` is reference-only (Codex has no custom slash commands, so manage.sh installs the
  shared `SKILL.md` as a native Codex **skill** under `$CODEX_HOME/skills/`). Both just tell the agent
  to read `SKILL.md` and pass the right `--launch`.
- `manage.sh` — install (copy) / `--dev` (symlink) / `--uninstall`. Installs the core to
  `~/.remote-harness/{SKILL.md,scripts/,reference/}` plus the three per-agent entry files.

## Two directions (the core model)

Generic roles: **A** = machine the agent runs on; **P** = machine the code lives on (an ssh `<alias>`).
- **reverse**: A = remote box, P = laptop behind NAT → reverse SSH tunnel; orchestrated by
  `laptop-setup.sh` running on the laptop.
- **forward**: A = local machine, P = directly-ssh-reachable server → direct ssh; orchestrated by
  `local-setup.sh` running locally.
Both: sshfs-mount P's project onto an empty dir on A, inject "build on `<alias>`" via `inject-rule.sh`,
launch the agent in the mount.

## Invariants — do NOT break these

1. **`laptop-setup.sh` must stay runnable STANDALONE.** In reverse it is fetched to the laptop (which
   has no install) and run there. It sources `_common.sh` via `. "$(dirname "$0")/_common.sh"`, so the
   emitted one-command fetches BOTH files into one temp dir. Don't add dependencies that only exist
   in the install dir.
2. **Always confirm, never auto-infer.** Direction, the code location, and the mountpoint must each be
   an explicit user choice (detection only pre-fills). See SKILL.md "Confirm, don't infer".
3. **`inject-rule.sh` is direction-neutral and never writes the mounted repo.** Per-session artifacts
   live under `$RH_HOME/.sessions/<key>`. Rule wording uses `<alias>` / "this machine".
4. **Shell-quote every value spliced into a remote command** with `sq()` (from `_common.sh`) — paths
   may contain apostrophes; unquoted interpolation is an injection/break risk. Never `eval` `--via`.
5. **Portability**: target Linux, WSL, and macOS. Use `#!/usr/bin/env bash`; avoid GNU-only flags
   (provide BSD fallbacks); listener checks go `ss → netstat -an → lsof`; sshfs install hints are
   OS-aware; **macOS uses FUSE-T (no kernel extension), never macFUSE**. `set -uo pipefail` (not `-e`)
   on probes that must keep emitting.
6. **Scripts emit `KEY=VALUE` on stdout, human notes on stderr.** Keep that contract; consumers parse it.

## Conventions

- **Bilingual docs (REQUIRED):** every Markdown doc MUST have a Chinese counterpart named
  `<name>.cn.md` (Chinese is the primary audience). **Exceptions:** `README.md` (it is inline
  bilingual, 中文 first) and `CLAUDE.md` (a symlink). When you add or edit any `*.md`, create/update
  its `*.cn.md` in the same change so they stay in sync. Examples: `SKILL.md`→`SKILL.cn.md`,
  `reference/reverse.md`→`reference/reverse.cn.md`, `adapters/codex.md`→`adapters/codex.cn.md`.
- Keep `SKILL.md` lean; put depth in `reference/`.
- One responsibility per script; share via `_common.sh`.

## Developing & testing

- `bash -n scripts/*.sh manage.sh` after every change (syntax gate).
- Dry-run pieces in a sandbox `HOME`/`RH_HOME` (e.g. `inject-rule.sh on … ; off …`; `preflight.sh
  --direction forward`; `mount-project.sh --unmount`). Verify reverse's managed-alias output is
  unchanged when touching `_common.sh`.
- Forward loopback E2E: add an ssh alias to `localhost`, run `local-setup.sh --via … --remote-path …
  --mountpoint /tmp/… --launch claude`; confirm mount + rule + unmount-on-exit.
- The full two-host E2E (reverse from a box / forward to a server, incl. macOS FUSE-T) is a manual test.
- Commit only when asked. The repo publishes to GitHub (`origin/main`).
- **Commit identity (required).** Every commit must carry a **GitHub noreply** email — GitHub rejects
  any push that would expose a real address (error `GH007`). On a clone with no configured git identity
  (e.g. a remote dev box), set it **per-commit** so nothing is written to `.git/config` or `--global`:
  `git -c user.name=chenjh16 -c user.email=chenjh16@users.noreply.github.com commit …`
- **Pushing.** Push only from the machine that holds GitHub push auth. To ship work done on a dev box
  without push access: commit there with the per-commit identity above, then from the push machine
  `git fetch` that box's clone (added as a remote) and `git push origin main`. While the box is the
  active source, don't also commit on the push machine — avoid divergence.
