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

## Speed: ask, don't fish

This flow must be **fast** — a few questions and the laptop command is ready. Two hard rules:

- **Never discover the user's project by remote search.** Do NOT run `list-projects.sh --via`, and do
  NOT `ssh <alias> 'find …'`/`ls` to hunt for the laptop project. It is slow and it routinely
  *misleads* — the project may live under a **different laptop account** than you'd guess (e.g. a
  `chenjh` tunnel but a `/Users/substance/…` project). The user types the path; `laptop-setup.sh`
  validates it on the laptop and re-prompts if wrong.
- **Recommend only from cheap, local/cached signals**, and always offer a typed "Other": the
  per-namespace cache (`session-cache.sh`), this box's `~/.ssh/config`, the cwd, and
  `connect-guesses.sh`. Probe locally **once**, then batch the questions.

A box account may also be **shared by several people**, each running to their own laptop — so the
tunnel (ssh alias + reverse port) is namespaced per **real user** (`RU`); confirming `RU` is one of
the batched questions below.

## Step 0 — One local probe (single Bash call; run each script ONCE)

```bash
RH="${RH_HOME:-$HOME/.remote-harness}"
"$RH/scripts/detect.sh"                                 # REALUSER_GUESS/SOURCE/CANDIDATES, SUGGESTED_PORT, DEFAULT_IDENTITY, SSHD_TCP_FORWARDING
"$RH/scripts/connect-guesses.sh"                        # candidate laptop→box `ssh …` strings
"$RH/scripts/session-cache.sh" get "<REALUSER_GUESS>"   # LAST_PROJECT_DIR/LAST_VIA/LAST_MOUNTPOINT (empty on first run)
"$RH/scripts/preflight.sh" --alias "<REALUSER_GUESS>-mac" --no-list   # tunnel up? + sshfs/FUSE + PROJECT_DIR/PROJECT_DIR_EMPTY (cwd)
```

Run all four in **one** Bash block and parse stdout (`KEY=VALUE`). Don't run a script twice to "see
stderr" — stderr is just human notes. `<REALUSER_GUESS>` comes from `detect.sh`; if it's **empty**,
drop the `session-cache get` and `preflight --alias` lines from this probe (there's no namespace yet),
confirm `RU` first in Step 1, then run `preflight --alias <RU>-mac` once. Read:

- `SSHD_TCP_FORWARDING=restricted-needs-attention` → warn the box sshd blocks reverse forwarding
  (`AllowTcpForwarding no|local`); the user must set `yes`/`remote` + restart sshd.
- `PREFLIGHT=ok` → your `<RU>-mac` tunnel already reaches your laptop (`TUNNEL_ALIAS`, `TUNNEL_PORT`,
  `LAPTOP_HOSTNAME`/`LAPTOP_USER`). This is the **reuse** path (incl. same-user / another-project — one
  tunnel carries any number of mounts): no new tunnel, just confirm the few values then emit-only.
- `PREFLIGHT=blocked` + `BLOCKED_STEP=sshfs` → show `REMEDY`, AskUserQuestion ("installed? ✅/⚠️"),
  re-run on ✅. `BLOCKED_STEP=tunnel` → you'll build it in Step 2.
- `LAST_*` present → a prior session for this namespace; use them as the **pre-filled defaults** below,
  so a repeat run is near one-click.

(`--alias <RU>-mac` makes preflight consider ONLY your own tunnel — on a shared account it must never
reuse another user's loopback alias and mount the wrong laptop. The mountpoint must be empty because
sshfs hides existing files.)

## Step 1 — Confirm direction, then ask everything in ONE batch

First confirm the **direction** (detection only pre-selects: `SSH_CONNECTION` set / `ON_REMOTE=1` ⇒
reverse). Confirm it **separately** — don't spend a batch slot on it. Then ask the reverse decisions
**together in ONE AskUserQuestion** (exactly these four; it takes up to 4) — every value pre-filled
from Step 0, every one with a free-form "Other". On a repeat run (cache hit) most are one-click
confirmations. "Which existing tunnel to reuse" IS question 1 (the namespace), not an extra question;
and the **connect string is question 4 of this same batch — never defer it to a later round** (it's
always needed and never depends on the others).

1. **Namespace `RU`** — pre-fill `REALUSER_GUESS`; offer `REALUSER_CANDIDATES` + Other. Your box alias
   is `<RU>-mac`, the reverse port is hashed stably from `RU`. (Empty guess ⇒ no safe default, ask.)
2. **Laptop project dir** — the codebase to develop. Pre-fill `LAST_PROJECT_DIR` if cached; otherwise
   the user **types the absolute path** (e.g. `/Users/you/proj`). **Never scanned, never hunted by
   search.** → `--project-dir`.
3. **Box mountpoint** — where it mounts on this box and the agent launches. Pre-fill `LAST_MOUNTPOINT`
   if cached and still empty; else recommend the cwd **only when empty** (`PROJECT_DIR_EMPTY=1` ⇒
   pre-select "Here: `<PROJECT_DIR>`" → pass `--remote-mountpoint '<PROJECT_DIR>'`); else recommend the
   auto `~/work/<basename>` (OMIT `--remote-mountpoint`) or let the user type a different EMPTY dir.
4. **Connect string** — how the laptop SSHes to this box (the tunnel dials back this way). Pre-fill
   `LAST_VIA` if cached, else the best `connect-guesses.sh` candidate; + Other (e.g.
   `-p 2222 you@203.0.113.20`, or a `~/.ssh/config` alias). Extract `CONNECT` = the ssh args without
   the leading `ssh`, and `HOST` = the host/alias token. Supported raw forms: host/alias, `user@host`,
   `-p`/`-l`/`-i`, `-J`/`-o ProxyJump=…` (no shell-quoting needed); for `ProxyCommand`/`-F`/quoted
   spaces, tell the user to use a `~/.ssh/config` Host alias and pass that.

**Laptop login user — do NOT ask, derive from the path, or warn about it.** The box logs into the
laptop as whoever runs the command there, and `laptop-setup.sh` authoritatively sets the box alias's
login user to the laptop's own **`id -un`** — the only correct value, because that is whose
`authorized_keys` receives the box key. So **never** derive a user from the project path's
`/Users/<x>/` and **never** warn about a home-dir-name mismatch (macOS home-dir names need not equal
usernames anyway); if the path is genuinely unreadable by that account, it surfaces honestly at mount
time. The `--user` you pass to `setup-tunnel.sh` in Step 2 is just a **seed** that laptop-setup
overrides — use `LAPTOP_USER` from preflight (reuse) or `LAPTOP_USER_GUESS` (else any non-empty
value).

`laptop-setup.sh` validates `--project-dir` on the laptop and loops/prompts if it's missing or
unreadable — so a typed path is safe; you don't need to validate it from the box.

## Step 2 — Build the box side, then remember the choices

If `PREFLIGHT=ok` and the confirmed project + `LOGIN_USER` match the live tunnel, skip to the
emit-only variant. Otherwise build the box endpoint (pass `--gen-key` when `DEFAULT_IDENTITY` is empty
— without a box key the Phase-5 login prompts for a password):

```bash
"$RH/scripts/setup-tunnel.sh" \
  --alias     <RU>-mac \
  --namespace <RU> \                # derive the STABLE reverse port from RU; omit --port
  --user      <USER_SEED> \         # seed ONLY — laptop-setup overrides it with the laptop's id -un
  [--identity <DEFAULT_IDENTITY>] \
  [--gen-key]
```

Capture `ALIAS` (`<RU>-mac`), `PORT` (the stable port — use it in the laptop command), `PUBKEY`
(re-run with `--gen-key` if empty).

Then **remember** the choices so the next run for this namespace pre-fills instantly — run this in
**both** paths (build and emit-only), right before emitting:

```bash
"$RH/scripts/session-cache.sh" put <RU> \
  "LAST_PROJECT_DIR=<LAPTOP_DIR>" "LAST_VIA=<CONNECT>" \
  "LAST_MOUNTPOINT=<BOX_MP>" "LAST_LAUNCH=<LAUNCH>"
```

## Step 3 — Emit the laptop command — then you are done

Print the following **exactly as shown** (short lines, `\`-continued, ≲70 chars each):

```
(
  d=$(mktemp -d "${TMPDIR:-/tmp}/rh.XXXXXX") || exit
  trap 'rm -rf "$d"' EXIT
  ssh -o ClearAllForwardings=yes <CONNECT_ARGS> \
    'cat ~/.remote-harness/scripts/_common.sh' \
    >"$d/_common.sh" &&
  ssh -o ClearAllForwardings=yes <CONNECT_ARGS> \
    'cat ~/.remote-harness/scripts/laptop-setup.sh' \
    >"$d/laptop-setup.sh" &&
  bash "$d/laptop-setup.sh" --host <HOST_Q> --port <PORT> \
    --via <CONNECT_Q> --box-alias <ALIAS_Q> --launch <LAUNCH> \
    [--remote-mountpoint <BOX_MP_Q>] --project-dir <LAPTOP_DIR_Q> [--yolo]
)
```
(Two fetches into one temp dir: `laptop-setup.sh` sources `_common.sh` from beside it. The laptop
usually has no install, so both files must be fetched together.)
(`ClearAllForwardings=yes` on the two fetches is required: the user's SSH alias may already contain
the previous `RemoteForward`, and a stale/live tunnel on the same port must not prevent downloading
the setup scripts.)
During Phase 2, `laptop-setup.sh` verifies that any existing listener on `<PORT>` actually reaches
this laptop (hostname + user). If the port is owned by another/stale tunnel, it scans the next 200
ports, rewrites the laptop `RemoteForward`, rewrites the box-side `<ALIAS>` with `setup-tunnel.sh`,
and continues on the first free port.
(`mktemp` avoids a predictable, world-writable `/tmp/rh.sh`; the subshell `trap` removes the temp dir
without masking the fetch/setup exit code.)
- `[--remote-mountpoint '<BOX_MP>']` = include only when **Step 1** chose an explicit box mountpoint
  (omit it for the `~/work/<name>` default). `--project-dir` should always be included. Both values
  must be user-confirmed, not guesses.
- Every `<..._Q>` placeholder is a shell word quoted with `sq()` semantics, not ad-hoc quotes. Example:
  `/Users/O'Neil/app` becomes `'/Users/O'\''Neil/app'`. Apply this to `--via`, `--host`,
  `--box-alias`, `--remote-mountpoint`, and `--project-dir`.
- `[--yolo]` only if the user asked to bypass approvals.
- `<CONNECT_ARGS>` = supported ssh args without the leading `ssh` word, e.g.
  `-p 2222 you@203.0.113.20`, used by the two fetches. `<CONNECT_Q>` is the same value shell-quoted
  for `--via`. Do not `eval`; for complex quoted SSH commands, require a Host alias.
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
> 1. Add the RemoteForward line to a dedicated harness ssh alias (leaving your normal ssh alias alone)
> 2. Reconnect automatically to activate the tunnel
> 3. Validate the confirmed project dir on the laptop and prompt again if it needs correction
> 4. Mount it on the remote box
> 5. Launch the agent on the remote — your terminal becomes the session
>    (the agent is told the code is a mount and to run builds/tests/linters back on your laptop)
>
> When you exit, the mount and tunnel are torn down automatically. Start remote-harness again
> anytime to reconnect (`/remote-harness` in Claude Code/opencode, `$remote-harness` in Codex).

**Your turn ends here.** The laptop-setup.sh script is self-contained and interactive —
it drives the rest of the flow on the user's machine. Do NOT AskUserQuestion about directories
or wait for further confirmation from this session.

### Emit-only variant (tunnel already up from preflight)

If preflight returned `PREFLIGHT=ok`, the tunnel exists but the user may want to remount or start a
new session. Still emit the same command (laptop-setup.sh is idempotent — Phase 1 is fast, it picks
up the project dir and launches the agent). Use `TUNNEL_ALIAS` as `<ALIAS>` and the live `TUNNEL_PORT`
as `<PORT>`. Pre-fill `<CONNECT>` / `<HOST>` from `LAST_VIA` (cache) if present — only re-ask when
there's no cached connect string. Still run the `session-cache.sh put` from Step 2 before emitting so
the cache stays current.

### Troubleshooting (if the user reports problems after running the command)

- **RemoteForward port not visible** → multiplexed master reuse: `ssh -O exit <host>`, reconnect.
- **Plain `ssh <host>` fails with `remote port forwarding failed ...`** → an older harness run may
  have written `RemoteForward` into the user's normal SSH alias. Current `laptop-setup.sh` creates a
  dedicated harness alias and removes that legacy line on the next run. Until then, connect with
  `ssh -o ClearAllForwardings=yes <host>` or remove the stale `RemoteForward` line manually.
- **`remote port forwarding failed for listen port <PORT>` before setup starts** → the fetch used an
  older command template without `-o ClearAllForwardings=yes`, so SSH tried to request the existing
  `RemoteForward` while downloading the scripts. Re-run `$remote-harness` after updating/installing
  this skill; the generated fetch lines now disable forwarding.
- **Remote port already listening but alias does not reach laptop** → another/stale tunnel owns the
  port. Current `laptop-setup.sh` tries the next free port automatically and updates both sides. If
  it cannot find/configure a free port, close that SSH session, or if it is a multiplexed master run
  `ssh -O exit <host>`, then rerun.
- **Several people sharing one box account** → each confirms a distinct namespace `RU` in Step 1, so
  each gets their own `<RU>-mac` alias and a reverse port hashed from `RU` — tunnels stay separate and
  `ssh <RU>-mac` always reaches that person's own laptop. If two people accidentally confirm the SAME
  `RU` (e.g. both accepted a generic guess), their alias/port collide; re-run and give distinct
  namespaces. The box-side `~/.ssh/config` edit is written atomically and `flock`-serialized so
  concurrent setups don't clobber each other's managed block.
- **Mount fails** with `STATUS=failed` → tunnel may not be up yet; wait a few seconds and retry
  the script. Or check `BOX_ALIAS` is the right alias on the box (`ssh <ALIAS> hostname` from box).
- **sshfs not installed on box** → the script offers to retry after the user installs it (the
  tunnel is kept; no need to restart from Step 0).
- **Password prompt when launching the agent** → wrong key or sshd off on laptop.
- **Files become unreadable mid-session / "Transport endpoint is not connected"** → the tunnel
  dropped (e.g. laptop slept), so the sshfs mount went stale. Exit the agent and re-run
  remote-harness — laptop-setup now detects the dead mount and remounts fresh (it no longer reuses a
  stale mount). In Codex, invoke it as `$remote-harness`.
