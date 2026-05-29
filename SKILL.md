---
name: remote-harness
description: >-
  Set up a remote development harness: this coding agent runs on a remote dev box, but you
  vibe-code on a project that lives on your LAPTOP. It opens a reverse SSH tunnel back to the
  laptop, then sshfs-mounts a chosen laptop directory onto your (empty) Claude Code project
  directory so the remote project becomes the project root — its CLAUDE.md/AGENTS.md and
  .claude settings take effect after you restart. Invoke when the user runs /remote-harness,
  or asks to work on their laptop's projects from this remote box.
---

# Remote Harness

You are a coding agent running **on a remote dev box** that the user reached by SSH from
their laptop. The code the user wants to work on **lives on the laptop**, not here. This
skill bridges that:

1. **Reverse tunnel** — make this box able to `ssh` back to the laptop, riding the SSH
   connection the user already opened (works through NAT).
2. **Pick a laptop directory** — list project dirs **on the laptop** (over the tunnel) and
   let the user pick one (or type a path / clone / create).
3. **Mount it onto your project dir (sshfs)** — mount that laptop directory onto the directory
   Claude Code was launched in (which must be **empty**), so the remote project becomes the
   Claude Code **project root**. Edits land on the laptop live.

So: the agent + compute are here; the files stay on the laptop; you reach *into* the laptop.

## Critical: empty project dir + a restart (read this)

Claude Code loads `CLAUDE.md` and `.claude/` settings **once, at launch, from the directory it
started in**. So to make the remote project's instructions and config actually take effect:

- The Claude Code **project dir must be empty** before mounting (mounting onto a non-empty dir
  would *hide* its files; and the remote project must cleanly become the root).
- After mounting, **restart Claude Code** in that same directory — the currently running
  session loaded its memory at launch and will NOT pick up the newly-mounted `CLAUDE.md`.
  (Equivalently: mount *before* launching, then `cd <dir> && claude` — no restart needed.)
- Claude Code reads **`CLAUDE.md`, not `AGENTS.md`**. If the project ships `AGENTS.md` only,
  add a `CLAUDE.md` that imports it (`@AGENTS.md`) or run `/init`.

## How the reverse tunnel works (keep this straight)

```
laptop ~/.ssh/config:  Host <theirhost>   ...   RemoteForward <PORT> 127.0.0.1:22
        └─ on `ssh <theirhost>`, this box's sshd listens on 127.0.0.1:<PORT> and forwards
           it back over the connection to the laptop's own sshd (127.0.0.1:22).

this box:  ssh <ALIAS>          →  127.0.0.1:<PORT>  →  (tunnel)  →  laptop:22
           sshfs <ALIAS>:/path  →  same alias        →  laptop files mounted at your project dir
```

The laptop only adds one `RemoteForward` line and reconnects; this box gets an `ssh` alias
pointing at `127.0.0.1:<PORT>`. The tunnel lives and dies with that laptop SSH session.

## Interaction

Whenever you need a value or decision, ask using your agent's interactive question tool (in
Claude Code that is **AskUserQuestion**; in Codex/opencode just ask in chat) and **wait for
the reply**. Offer a sensible default for every question (the scripts compute good ones).

## Helper scripts

```bash
RH="${RH_HOME:-$HOME/.remote-harness}"
[ -d "$RH/scripts" ] || echo "scripts missing — run the remote-harness manage.sh first"
```

- `"$RH/scripts/preflight.sh"` — **one-shot prerequisite check** (env + tunnel + sshfs/FUSE +
  empty project dir) in a single call. Emits `PREFLIGHT=ok` (with `TUNNEL_ALIAS`, laptop info,
  and candidates after a `---PROJECTS---` line) or `PREFLIGHT=blocked` + `BLOCKED_STEP` /
  `ERROR` / `REMEDY`. **Run this first**; the scripts below are for setting up / repairing a
  specific step.
- `"$RH/scripts/detect.sh"` — read-only environment probe (KEY=VALUE).
- `"$RH/scripts/setup-tunnel.sh"` — write this box's `ssh` alias; print the laptop-side
  `RemoteForward` line and this box's public key. Idempotent.
- `"$RH/scripts/check-tunnel.sh"` — verify the listener + a real `ssh` login through the tunnel.
- `"$RH/scripts/list-projects.sh --via <ALIAS>"` — list candidate project dirs **on the
  laptop** over the tunnel (omit `--via` to scan this box instead).
- `"$RH/scripts/mount-project.sh"` — sshfs-mount a laptop dir onto your project dir (default
  `$PWD`; refuses a non-empty target) or `--unmount`.

Parse the `KEY=VALUE` lines from each script's **stdout**; human notes go to stderr. Each
`PROJECT` line is tab-separated: `PROJECT<TAB>path<TAB>git:branch|-` (paths may contain spaces).

---

## Step 0 — Preflight (one shot — do this first)

Run **once**: `"$RH/scripts/preflight.sh"`. It checks environment, tunnel, sshfs/FUSE, and an
empty project dir in a single process, stopping at the first blocker. Read `PREFLIGHT`:

- **`PREFLIGHT=ok`** → everything's ready. The output carries `TUNNEL_ALIAS`, `TUNNEL_PORT`,
  `LAPTOP_HOSTNAME`/`LAPTOP_USER`, `PROJECT_DIR`, and the laptop's candidate dirs after a
  `---PROJECTS---` line. **Go straight to Step 2** using these — do NOT re-run
  detect/check-tunnel/list as separate calls.
- **`PREFLIGHT=blocked`** → show `ERROR` + `REMEDY`, then handle `BLOCKED_STEP`:
  - `tunnel` → no working back-channel → **Step 1** (set up / repair), then re-run preflight.
  - `sshfs` → install sshfs/FUSE per `REMEDY`, then re-run preflight.
  - `project-dir` → cwd isn't empty → have the user relaunch Claude Code in a fresh empty
    project dir, then re-run preflight.

Only reach for the individual scripts (`detect.sh`, `check-tunnel.sh`) to debug a blocker.

## Step 1 — Reverse tunnel (only when preflight's `BLOCKED_STEP=tunnel`)

Run `"$RH/scripts/detect.sh"` for setup defaults (`SUGGESTED_PORT`, `LAPTOP_USER_GUESS`,
`DEFAULT_IDENTITY`, and `SSHD_TCP_FORWARDING` — if `restricted-needs-attention`, warn the user
that this box's sshd blocks reverse forwarding and must be set to `yes`/`remote` + restarted).
Gather (offer defaults), then act:

1. **Alias** to reach the laptop from here. Default `${LAPTOP_USER_GUESS}-mac`, else `laptop`.
2. **Laptop SSH username.** Default `LAPTOP_USER_GUESS`; if empty, ask.
3. **Tunnel port** (loopback port on THIS box). Default `SUGGESTED_PORT`. Must be **below
   `EPHEMERAL_LOW`** and **different from the user's login port** (avoid confusion).
4. **Identity key.** Use `DEFAULT_IDENTITY` if present; else generate one (pass `--gen-key`)
   and its public key must go into the laptop's `~/.ssh/authorized_keys`.

```bash
"$RH/scripts/setup-tunnel.sh" --alias <ALIAS> --port <PORT> --user <LAPTOP_USER> \
    [--identity <DEFAULT_IDENTITY>] [--gen-key]
```

Capture `REMOTEFORWARD_LINE` and `PUBKEY`. Then instruct the user, **on their laptop** (wait):

1. Enable SSH server / Remote Login (macOS: `sudo systemsetup -setremotelogin on`).
2. Put `PUBKEY` into the laptop's `~/.ssh/authorized_keys`.
3. Add `<REMOTEFORWARD_LINE>` to the `Host` block they already use to reach this box —
   **without changing their login `Port`**. Do **not** add `ExitOnForwardFailure yes`.
4. Reconnect cleanly: close existing sessions; if they multiplex, `ssh -O exit <host>`; then
   `ssh <host>` again.

Verify with `"$RH/scripts/check-tunnel.sh" --alias <ALIAS> --port <PORT>`. If `SSH=down`, use
the troubleshooting playbook below and loop until `SSH=up`.

### Troubleshooting (check-tunnel shows SSH=down)

- `LISTENER=down` → the laptop's `RemoteForward` didn't take effect: multiplexed master reuse
  (`ssh -O check/exit <host>`, close old terminals, reconnect); the line wasn't saved / wrong
  `Host` block (`ssh -G <host> | grep -i remoteforward` must show `<PORT>`); or an old session
  still holds the port (only the first session binds it; the holder must close first).
- `LISTENER=up` but `SSH=down` → back-channel exists but laptop login fails: laptop sshd off,
  this box's key not in the laptop's `authorized_keys`, or wrong username. Read `ERROR`.
- A **password prompt** when they `ssh <host>` → they hit the wrong sshd (often a missing
  `Port`). Check `ssh -G <host>` and compare the server host-key fingerprint.

## Step 2 — Select a laptop directory and mount it

Preflight already confirmed the project dir is empty and returned the candidates +
`TUNNEL_ALIAS` (use it as `<ALIAS>`).

1. **Choose the laptop directory:** from the `PROJECT` candidates in the preflight output, use
   your interactive tool to let the user pick one, type an absolute laptop path, clone a repo
   (`ssh <ALIAS> 'git -C <parent> clone <url>'`), or make a new dir. (Re-run
   `"$RH/scripts/list-projects.sh" --via <ALIAS> --root <dir>` only to look elsewhere.) Resolve
   to `REMOTE_PATH`.
2. **Mount it onto the project dir:**
   ```bash
   "$RH/scripts/mount-project.sh" --alias <ALIAS> --remote-path "<REMOTE_PATH>"
   ```
   (defaults to `$PWD`; refuses a non-empty target). Handle:
   - `STATUS=need-sshfs` → show `INSTALL_CMD` (`sudo apt-get install -y sshfs`); ask the user
     to run it (sudo); re-run.
   - `STATUS=not-empty` → project dir isn't empty (see step 1).
   - `STATUS=mounted` → note `MOUNTPOINT`. If `AGENTS_MD_ONLY=1`, the project ships `AGENTS.md`
     but no `CLAUDE.md`; offer to add one so Claude Code reads it:
     `printf '@AGENTS.md\n' > "<MOUNTPOINT>/CLAUDE.md"` (this writes into the laptop repo —
     confirm first; `/init` is an alternative).
   - `STATUS=failed` → read `ERROR` (often the tunnel dropped — re-check Step 1; or the laptop
     sshd lacks the sftp subsystem, which macOS Remote Login enables by default).

## Step 3 — Restart Claude Code so the project takes effect

The remote project is now mounted at your project dir, but **the running session loaded its
memory at launch and won't see the project's `CLAUDE.md`/settings until it restarts.** Tell the
user:

> Mounted `<ALIAS>:<REMOTE_PATH>` onto `<project-dir>`. Now `/exit` and run `claude` again in
> this same directory — it starts with the remote project as its root and loads its
> `CLAUDE.md`/`AGENTS.md` and `.claude/` settings.

The tunnel and mount persist across the restart. (If you'd mounted *before* launching, no
restart would be needed.)

## Step 4 — Vibe coding (after the restart)

In the relaunched session the project dir **is** the remote project — edit files normally;
every change writes straight to the laptop. Builds/tests that need the laptop's toolchain run
over the tunnel, e.g. `ssh <ALIAS> 'cd <REMOTE_PATH> && <build/test cmd>'`. Expect slightly
higher latency than true-local files (network FS) — prefer targeted reads/greps. When done:
`"$RH/scripts/mount-project.sh" --alias <ALIAS> --unmount --mountpoint "<project-dir>"`.
If the laptop disconnects the mount stalls — reconnect, then re-run `/remote-harness`.

### Optional hardening (mention, don't auto-apply)

If this remote box's sshd is internet-exposed, once key login works suggest disabling
password auth (`PasswordAuthentication no`, `PermitRootLogin prohibit-password`, `sshd -t`,
restart). Never before key login is verified.
