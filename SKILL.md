---
name: remote-harness
description: >-
  Set up a remote development harness: this coding agent runs on a remote dev box, but you
  vibe-code on a project that lives on your LAPTOP. Invoke when the user runs /remote-harness.
  The agent sets up a reverse SSH tunnel (Steps 0-1), then hands the user ONE command to run
  on their laptop — that command handles everything else: prompts for a project dir (readline,
  defaults to the current dir), mounts it on the remote box, and launches the chosen agent
  (claude/codex/opencode) there in a fresh session.
---

# Remote Harness

## What this skill does

You are a coding agent on a **remote dev box**. The user's code lives on their **laptop**.
This skill connects the two:

1. **Agent side (Steps 0–1):** establish a reverse SSH tunnel so this box can reach the laptop.
2. **Laptop side (one command, fully automated):** `laptop-setup.sh` handles everything else —
   reconnects with the new config (which carries `RemoteForward`), lets the user pick a laptop
   project dir (readline prompt, defaults to cwd), mounts it on the remote box via sshfs, and
   launches the agent there via `ssh -t`.

The chosen laptop project is sshfs-mounted onto an **empty** box dir, and the agent launches there.
sshfs hides existing contents, so the mountpoint must be empty:
- If you invoked `/remote-harness` from an **empty** dir, that exact dir is used (passed as
  `--remote-mountpoint`), so the agent launches right where you started.
- Otherwise laptop-setup falls back to `~/work/<project-name>` on the box (a fresh empty dir).

## How the reverse tunnel works

```
laptop ~/.ssh/config:  Host <alias>   RemoteForward <PORT> 127.0.0.1:22
        └─ on connect, this box's sshd listens on 127.0.0.1:<PORT> and forwards back to laptop:22

this box:  ssh <BOX_ALIAS>          → 127.0.0.1:<PORT> → (tunnel) → laptop:22
           sshfs <BOX_ALIAS>:/path  → same tunnel      → laptop files mounted here
```

The laptop just needs to reconnect with `RemoteForward` in its config.
The `BOX_ALIAS` (e.g. `my-mac`) is the alias this box uses to reach the laptop.

## Interaction — keep the flow continuous

This skill is **one continuous agent-driven flow from Step 0 to handing over the laptop command**.
Whenever a step is blocked, use your interactive question tool (AskUserQuestion in Claude Code;
chat in Codex/opencode) to guide the user — never end your turn and passively wait.

> **Cross-agent note:** wherever the steps below say "**AskUserQuestion**", that is the Claude Code
> tool. If you are running in **Codex or opencode** (no such tool), instead just ask the question in
> chat — present the same options as a short list — and wait for the user's reply before continuing.

The **only legitimate places to stop** are:
- `sshfs` blocked: give install cmd, AskUserQuestion ("installed? ✅/⚠️"), re-run on ✅.
- After Step 1: the user must run the command on their laptop. At that point, the laptop-setup
  script takes over completely — it is self-contained and interactive on the laptop side.
  **The agent's job is done once it hands the user that command.**

## Invocation options

The user may pass a free-form request when invoking the skill (e.g. `/remote-harness 开启yolo模式`,
`/remote-harness yolo`, "...bypass approvals"). Parse that text for intent and apply it in Step 1c:

- **YOLO / bypass approvals** (any of: "yolo", "bypass approvals", "skip permissions", "危险模式",
  "免审批", "开启yolo模式") → start the remote agent with its bypass flag (mapping in Step 1c's
  `<LAUNCH>` note). Confirm with the user once if intent is ambiguous; otherwise just apply it.

If no such request is present, launch the remote agent normally (with approvals on).

## Helper scripts

```bash
RH="${RH_HOME:-$HOME/.remote-harness}"
[ -d "$RH/scripts" ] || echo "scripts missing — run: manage.sh"
```

- `"$RH/scripts/preflight.sh"` — one-shot check: environment, sshfs/FUSE, tunnel. Emits
  `PREFLIGHT=ok|blocked` + `BLOCKED_STEP`/`ERROR`/`REMEDY`. Run this first.
- `"$RH/scripts/detect.sh"` — read-only probe: `SUGGESTED_PORT`, `LAPTOP_USER_GUESS`,
  `DEFAULT_IDENTITY`, `SSHD_TCP_FORWARDING`. Used when building the tunnel.
- `"$RH/scripts/setup-tunnel.sh"` — write the box-side `ssh` alias (`BOX_ALIAS → 127.0.0.1:PORT`).
  Emits `ALIAS`, `PORT`, `PUBKEY`, `REMOTEFORWARD_LINE`. Idempotent.
- `"$RH/scripts/connect-guesses.sh"` — guess how the laptop reaches this box (for Step 1 prompt).
- `"$RH/scripts/check-tunnel.sh"` — verify listener + real ssh login through the tunnel.
- `"$RH/scripts/laptop-setup.sh"` — **runs on the LAPTOP**: Phases 1-5 fully automated.
  Phase 1: SSH server, authorized key, RemoteForward config. Phase 2: reconnect. Phase 3:
  pick project dir (readline prompt, defaults to cwd). Phase 4: sshfs mount on remote (retries
  interactively on sshfs-missing / non-empty). Phase 5: inject the run-on-laptop rule (see below),
  then launch the chosen agent (`--launch`, default `claude`).
- `"$RH/scripts/inject-rule.sh"` — **runs on the BOX**:
  `on <agent> <laptop_path> <box_alias> <box_mountpoint> [yolo]` builds box-side **per-session**
  artifacts under `$RH_HOME/.sessions/<key>` (key from the mountpoint) and prints how to launch so
  ONLY this session reads the rule — **nothing global, nothing in the mounted repo**, so other
  projects on the box are unaffected. It prints `RH_STATUS`, `RH_LAUNCH_ENV`, `RH_LAUNCH_FLAGS`:
    - claude   → `RH_LAUNCH_FLAGS=--append-system-prompt-file <rule>` (session flag)
    - opencode → `RH_LAUNCH_ENV=OPENCODE_CONFIG=<session cfg>` (instructions; +`permission:"allow"` if yolo)
    - codex    → `RH_LAUNCH_ENV=CODEX_HOME=<session home>` (your real auth/config symlinked; our `AGENTS.md`)
  The rule tells the agent its cwd is an sshfs mount and to run builds/tests/linters/installs/the app
  **on the laptop** via `ssh <box_alias> 'cd <laptop_path> && <cmd>'`, warns **not** to install/build
  on the box (pollutes the mount, wrong-arch binaries), and lists **stack-tailored example commands**
  sniffed from the project's manifests. laptop-setup splices `RH_LAUNCH_ENV`/`RH_LAUNCH_FLAGS` into
  the launch and calls `off <agent> <box_mountpoint>` (removes the session dir) on exit.

Parse `KEY=VALUE` from each script's stdout; human notes go to stderr.

---

## Step 0 — Preflight (one call, one decision)

```bash
"$RH/scripts/preflight.sh" --no-list   # --no-list: skip the (now-unused) over-tunnel project scan
```

Read `PREFLIGHT`:

- **`ok`** → tunnel already works (`TUNNEL_ALIAS`, `TUNNEL_PORT`, `LAPTOP_HOSTNAME`).
  The tunnel is up — emit the laptop command immediately (see Step 1 § emit-only variant).
- **`blocked`** — handle `BLOCKED_STEP`:
  - `tunnel` → no working back-channel → go to **Step 1** (below).
  - `sshfs` → sshfs/FUSE missing: show `REMEDY`, AskUserQuestion ("installed? ✅/⚠️"),
    re-run on ✅; on ⚠️ read the problem and help. Loop until resolved.

**`PROJECT_DIR` / `PROJECT_DIR_EMPTY` decide the mountpoint, not whether to proceed** — always
proceed (the mountpoint must be empty because sshfs hides existing files):
- `PROJECT_DIR_EMPTY=1` (cwd empty) → remember `PROJECT_DIR` and pass it as `--remote-mountpoint
  '<PROJECT_DIR>'` in Step 1c, so the agent launches in your invoking dir.
- `PROJECT_DIR_EMPTY=0` (cwd non-empty) → **omit** `--remote-mountpoint`; laptop-setup mounts at
  `~/work/<project-name>` on the box instead. (Do NOT pass a non-empty cwd as the mountpoint — the
  mount would refuse it.)

## Step 1 — Build the tunnel and hand over to the laptop

### 1a. Set up the box side

```bash
"$RH/scripts/detect.sh"   # get SUGGESTED_PORT, LAPTOP_USER_GUESS, DEFAULT_IDENTITY
```

If `SSHD_TCP_FORWARDING=restricted-needs-attention`: warn that this box's sshd blocks reverse
forwarding (`AllowTcpForwarding no|local`) — user must set it to `yes`/`remote` + restart sshd.

```bash
"$RH/scripts/setup-tunnel.sh" \
  --alias <LAPTOP_USER_GUESS>-mac \
  --port  <SUGGESTED_PORT> \
  --user  <LAPTOP_USER_GUESS> \
  [--identity <DEFAULT_IDENTITY>]
```

Capture from output: `ALIAS` (box-side alias, e.g. `my-mac`), `PORT`.

### 1b. Ask how the user connects to this box

```bash
"$RH/scripts/connect-guesses.sh"   # candidate ssh commands (user+public/LAN IP)
```

**AskUserQuestion**: "How do you ssh into this box from your laptop?"
- Offer each guess as an option (e.g. `ssh you@203.0.113.10`)
- Plus Other (free-text for their real command, e.g. `ssh -p 2222 you@203.0.113.20`)

From their answer extract:
- `CONNECT` = the ssh *arguments only* (strip the leading `ssh` word if present),
  e.g. `-p 2222 you@203.0.113.20`
- `HOST` = the host/alias token, e.g. `203.0.113.20` or `my-box`

### 1c. Emit the laptop command — then you are done

Print the following **exactly as shown** (short lines, `\`-continued, ≲70 chars each):

```
rh=$(mktemp "${TMPDIR:-/tmp}/rh.XXXXXX") \
  && ssh <CONNECT> 'cat ~/.remote-harness/scripts/laptop-setup.sh' >"$rh" \
  && bash "$rh" --host <HOST> --port <PORT> --via '<CONNECT>' \
       --box-alias <ALIAS> --launch <LAUNCH> \
       [--remote-mountpoint '<PROJECT_DIR>'] [--yolo]; rm -f "$rh"
```
(`mktemp` avoids a predictable, world-writable `/tmp/rh.sh` and creates the file 0600.)
- `[--remote-mountpoint '<PROJECT_DIR>']` = include ONLY when your invoking cwd is empty
  (`PROJECT_DIR_EMPTY=1`); the laptop project mounts there and the agent launches there. If the cwd
  is non-empty, OMIT this flag — laptop-setup mounts at `~/work/<project-name>` instead.
- `[--yolo]` only if the user asked to bypass approvals.
- `<CONNECT>` = ssh args without the leading `ssh` word, e.g. `-p 2222 you@203.0.113.20`.
  Pass exactly the same value to both the initial `ssh` call and `--via`.
- `<LAUNCH>` = the **bare** coding-agent CLI to start on the remote — **the CLI of the agent you
  (the assistant) are running in**: `claude` (Claude Code), `codex` (Codex), `opencode` (opencode).
  (Default `claude`; the Codex/opencode adapters tell you which.) The remote box must have it installed.
  laptop-setup launches it through a **login shell** (`exec "${SHELL:-/bin/bash}" -lic ...`), so a CLI
  in `~/.local/bin` (added to PATH by `~/.profile`/`~/.zshrc`) is found without a full path.
- **YOLO / bypass approvals:** if the user's invocation requested it (see "Invocation options"),
  add **`--yolo`** to the `bash /tmp/rh.sh ...` command. `laptop-setup.sh` then applies the right
  bypass per agent: claude → `--dangerously-skip-permissions`; codex →
  `--dangerously-bypass-approvals-and-sandbox`; opencode → `permission:"allow"` in its
  **per-session** config only (no global change; gone when the session dir is removed on exit).
  Only add `--yolo` when explicitly asked.

Tell the user:

> Run this **on your laptop** (in a local terminal, not this session). It will:
> 1. Add the RemoteForward line to your ssh config (creating a `<BOX_USER>-remote` alias if needed)
> 2. Reconnect automatically to activate the tunnel
> 3. Prompt you for the project dir to develop (defaults to the current dir; press Enter to accept)
> 4. Mount it on the remote box
> 5. Launch the agent on the remote — your terminal becomes the session
>    (the agent is told the code is a mount and to run builds/tests/linters back on your laptop)
>
> When you exit, the mount and tunnel are torn down automatically. Run `/remote-harness` again
> anytime to reconnect.

**Your turn ends here.** The laptop-setup.sh script is self-contained and interactive —
it drives the rest of the flow on the user's machine. Do NOT AskUserQuestion about directories
or wait for further confirmation from this session.

### Emit-only variant (tunnel already up from preflight)

If preflight returned `PREFLIGHT=ok`, the tunnel exists but the user may want to remount or
start a new session. In that case still emit the same command (laptop-setup.sh is idempotent —
Phase 1 will be fast, it picks up the project dir and launches the agent). Use `TUNNEL_ALIAS`
as `<ALIAS>` and derive `<CONNECT>` / `<HOST>` from the existing alias or re-ask the user.

### Troubleshooting (if the user reports problems after running the command)

- **RemoteForward port not visible** → multiplexed master reuse: `ssh -O exit <host>`, reconnect.
- **Mount fails** with `STATUS=failed` → tunnel may not be up yet; wait a few seconds and retry
  the script. Or check `BOX_ALIAS` is the right alias on the box (`ssh <ALIAS> hostname` from box).
- **sshfs not installed on box** → the script offers to retry after the user installs it (the
  tunnel is kept; no need to restart from Step 0).
- **Password prompt when launching the agent** → wrong key or sshd off on laptop.
- **Files become unreadable mid-session / "Transport endpoint is not connected"** → the tunnel
  dropped (e.g. laptop slept), so the sshfs mount went stale. Exit the agent and re-run
  `/remote-harness` — laptop-setup now detects the dead mount and remounts fresh (it no longer
  reuses a stale mount).
