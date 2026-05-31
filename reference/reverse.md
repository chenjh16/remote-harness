# Reverse direction — agent on a remote box, code on your laptop

The agent runs on a **remote box**; the code is on the user's **laptop** (behind NAT). The box can't
dial the laptop, so the laptop opens a **reverse SSH tunnel** and the laptop project is sshfs-mounted
onto the box. You (the agent, on the box) build the tunnel endpoint and hand the user ONE command to
run on their laptop; `laptop-setup.sh` does the rest there. Honor the **"Confirm, don't infer"** rule
and the cross-agent question tool policy from SKILL.md for every choice. Helper-script contracts:
`$RH/reference/scripts.md`.

## How the reverse tunnel works

```
laptop ~/.ssh/config:  Host <alias>   RemoteForward <PORT> 127.0.0.1:22
        └─ on connect, this box's sshd listens on 127.0.0.1:<PORT> and forwards back to laptop:22

this box:  ssh <BOX_ALIAS>          → 127.0.0.1:<PORT> → (tunnel) → laptop:22
           sshfs <BOX_ALIAS>:/path  → same tunnel      → laptop files mounted here
```

The laptop just needs to reconnect with `RemoteForward` in its config. The `BOX_ALIAS` (e.g.
`my-mac`) is the alias this box uses to reach the laptop.

## Step 0 — Preflight (one call, one decision)

```bash
"$RH/scripts/preflight.sh" --no-list   # --no-list: defer project scan to §1b.5 (only after tunnel is confirmed up)
```

Read `PREFLIGHT`:

- **`ok`** → tunnel already works (`TUNNEL_ALIAS`, `TUNNEL_PORT`, `LAPTOP_HOSTNAME`).
  The tunnel is up — emit the laptop command immediately (see § emit-only variant).
- **`blocked`** — handle `BLOCKED_STEP`:
  - `tunnel` → no working back-channel → go to **Step 1** (below).
  - `sshfs` → sshfs/FUSE missing: show `REMEDY`, AskUserQuestion ("installed? ✅/⚠️"),
    re-run on ✅; on ⚠️ read the problem and help. Loop until resolved.

`PROJECT_DIR` / `PROJECT_DIR_EMPTY` feed the **box mountpoint** decision in Step 1b.5 (they don't
gate proceeding). The mountpoint must be empty because sshfs hides existing files.

## Step 1 — Build the tunnel and hand over to the laptop

### 1a. Set up the box side

```bash
"$RH/scripts/detect.sh"   # get SUGGESTED_PORT, LAPTOP_USER_GUESS, DEFAULT_IDENTITY
```

If `SSHD_TCP_FORWARDING=restricted-needs-attention`: warn that this box's sshd blocks reverse
forwarding (`AllowTcpForwarding no|local`) — user must set it to `yes`/`remote` + restart sshd.

If `DEFAULT_IDENTITY` came back **empty** (this box has no SSH key yet), pass `--gen-key` so
`setup-tunnel.sh` creates an ed25519 key and emits a non-empty `PUBKEY`. Without it the tunnel has no
key to authorize on the laptop, and the Phase-5 login later fails with a password prompt.

```bash
"$RH/scripts/setup-tunnel.sh" \
  --alias <LAPTOP_USER_GUESS>-mac \
  --port  <SUGGESTED_PORT> \
  --user  <LAPTOP_USER_GUESS> \
  [--identity <DEFAULT_IDENTITY>] \
  [--gen-key]   # add this when DEFAULT_IDENTITY is empty (no existing box key)
```

Capture from output: `ALIAS` (box-side alias, e.g. `my-mac`), `PORT`, `PUBKEY`. If `PUBKEY` is
empty, re-run with `--gen-key`.

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

### 1b.5 Confirm BOTH directories (required — ask, don't assume)

Before emitting, confirm with the user (AskUserQuestion; detected values are defaults, not decisions):

1. **Box mountpoint** — where the project mounts on THIS box and the agent launches. Options:
   - "Here: `<PROJECT_DIR>` (my current dir)" — only valid if empty (`PROJECT_DIR_EMPTY=1`); pre-select
     this when empty. → pass `--remote-mountpoint '<PROJECT_DIR>'`.
   - "A fresh `~/work/<project-name>` on the box (auto)" — pre-select this when the cwd is non-empty.
     → OMIT `--remote-mountpoint` (laptop-setup derives it).
   - Other (a different EMPTY box dir) → pass `--remote-mountpoint '<that dir>'`.
2. **Laptop project dir** — which codebase to develop:
   - If the tunnel is already up (`PREFLIGHT=ok`): run `"$RH/scripts/list-projects.sh" --via
     <TUNNEL_ALIAS>`, then AskUserQuestion "Which project on your laptop?" (each path + Other
     free-text). → pass `--project-dir '<LAPTOP_DIR>'`.
   - If the tunnel is NOT up yet (you just built it in Step 1, can't reach the laptop): OMIT
     `--project-dir` and tell the user the command will prompt them for the laptop project dir
     (that readline prompt IS the confirmation).

### 1c. Emit the laptop command — then you are done

Print the following **exactly as shown** (short lines, `\`-continued, ≲70 chars each):

```
d=$(mktemp -d "${TMPDIR:-/tmp}/rh.XXXXXX") \
  && ssh <CONNECT> 'cat ~/.remote-harness/scripts/_common.sh'     >"$d/_common.sh" \
  && ssh <CONNECT> 'cat ~/.remote-harness/scripts/laptop-setup.sh' >"$d/laptop-setup.sh" \
  && bash "$d/laptop-setup.sh" --host <HOST> --port <PORT> --via '<CONNECT>' \
       --box-alias <ALIAS> --launch <LAUNCH> \
       [--remote-mountpoint '<BOX_MP>'] [--project-dir '<LAPTOP_DIR>'] [--yolo]; rm -rf "$d"
```
(Two fetches into one temp dir: `laptop-setup.sh` sources `_common.sh` from beside it. The laptop
usually has no install, so both files must be fetched together.)
(`mktemp` avoids a predictable, world-writable `/tmp/rh.sh` and creates the file 0600.)
- `[--remote-mountpoint '<BOX_MP>']` / `[--project-dir '<LAPTOP_DIR>']` = include each ONLY as
  decided in **1b.5** (omit when you chose the `~/work/<name>` default, or when the laptop dir is
  left to the on-laptop prompt). Both must be the user-confirmed values, not guesses.
- `[--yolo]` only if the user asked to bypass approvals.
- `<CONNECT>` = ssh args without the leading `ssh` word, e.g. `-p 2222 you@203.0.113.20`.
  Pass exactly the same value to both the initial `ssh` call and `--via`.
- `<LAUNCH>` = the **bare** coding-agent CLI to start on the remote — **the CLI of the agent you
  (the assistant) are running in**: `claude` (Claude Code), `codex` (Codex), `opencode` (opencode).
  (Default `claude`; use the CLI you are running in.) The remote box must have it installed.
  laptop-setup launches it through a **login shell** (`exec "${SHELL:-/bin/bash}" -lic ...`), so a CLI
  in `~/.local/bin` (added to PATH by `~/.profile`/`~/.zshrc`) is found without a full path.
- **YOLO / bypass approvals:** if requested (see SKILL.md "Invocation options"), add **`--yolo`**.
  `laptop-setup.sh` then applies the right bypass per agent: claude →
  `--dangerously-skip-permissions`; codex → `--dangerously-bypass-approvals-and-sandbox`; opencode →
  `permission:"allow"` in its **per-session** config only (no global change; gone on exit).

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
