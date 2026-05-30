# remote-harness

A portable coding-agent skill for **vibe-coding on your laptop's projects using a remote dev
box's agent**. The coding agent runs on the remote box (more compute / always-on), but your
code stays on your laptop. The skill:

1. opens a **reverse SSH tunnel** from the remote box back to your laptop (works through NAT), then
2. lists project directories **on your laptop**, lets you pick one, and
3. **sshfs-mounts** it onto your (empty) Claude Code project directory so the remote project
   becomes the project root — its CLAUDE.md/AGENTS.md + .claude settings apply after you
   restart Claude Code there. Edits land on your laptop, live.

Invoke it as `/remote-harness` inside Claude Code, Codex, or opencode.

## The topology

You sit at a laptop (behind NAT) and SSH into a remote dev box where the agent runs. The box
can't dial your laptop back directly, so your laptop opens a back-channel on the SSH
connection it already makes — one `RemoteForward` line. Then sshfs rides that same channel:

```
laptop ── ssh ──▶ remote dev box (agent runs here)
  ▲                     │
  └── RemoteForward ◀───┘   box's 127.0.0.1:<PORT> ──tunnel──▶ laptop:22

on the box:  ssh <alias>           → laptop shell
             sshfs <alias>:/proj   → laptop's /proj mounted at your (empty) project dir
                                      (restart claude there; edits write to the laptop)
```

The tunnel and mount live and die with that laptop SSH session.

## Requirements

- You already SSH from your laptop into the remote dev box (any port / jump host is fine).
- **Laptop**: SSH server enabled (macOS: Remote Login — it includes the sftp subsystem sshfs
  needs), and the **remote box's public key** in the laptop's `~/.ssh/authorized_keys`. The
  skill prints the exact key and config line to add.
- **Remote box**: sshd allows TCP forwarding (default), plus **FUSE + `sshfs`** for mounting
  (`sudo apt-get install -y sshfs`; FUSE is usually already present). The skill detects and
  prompts if sshfs is missing.

## Install

Run the installer on the **remote dev box** (where your coding agent runs):

```bash
./manage.sh                 # install (copy) for all agents
./manage.sh claude codex    # only the named agents
./manage.sh --dev           # DEV install: symlink to this repo, edits go live immediately
./manage.sh --uninstall     # remove everything (or: --uninstall codex for one agent)
./manage.sh --help
```

`--dev` symlinks the installed paths back to this repo (handy while developing the skill).
Uninstall removes only the installed files/links — it never touches your `~/.ssh` tunnel
config or any sshfs mounts. Removing all agents also drops the shared `~/.remote-harness`
core; removing a single agent leaves the core for the others.

| Agent       | Location                                            | Invoke           |
|-------------|-----------------------------------------------------|------------------|
| shared core | `~/.remote-harness/{SKILL.md,scripts/}`             | (used by all)    |
| Claude Code | `~/.claude/skills/remote-harness/SKILL.md`          | `/remote-harness`|
| Codex       | `~/.codex/prompts/remote-harness.md`                | `/remote-harness`|
| opencode    | `~/.config/opencode/command/remote-harness.md`      | `/remote-harness`|

The **scripts** are the single shared source of truth: every agent calls `~/.remote-harness/scripts/*`
(via `$RH_HOME`). The per-agent entry file differs by what each tool supports — Claude Code has a
native *skill* (its own copy of `SKILL.md`), while the Codex prompt and opencode command are thin
adapters that tell the agent to read the shared `~/.remote-harness/SKILL.md`. All are invoked as
`/remote-harness`.

## Usage

In your agent on the remote box: `/remote-harness`. It will (using your agent's interactive
prompt for decisions):

1. Run a **one-shot preflight** (environment, tunnel, sshfs/FUSE, empty project dir) — it stops
   at the first blocker with a detailed remedy, or returns the candidate dirs if all is ready.
2. If needed, set up the reverse tunnel: it **asks (with guesses) how you ssh into the box**, then
   hands you a **short, backslash-continued copy-paste command** for your laptop (no editing, no
   long lines the terminal could wrap and corrupt) that auto-detects macOS/Linux/WSL, ensures an
   SSH server, authorizes the key, and adds the `RemoteForward` — creating a tidy `<user>-remote`
   alias if you don't already have one. It then asks whether it worked (or what broke) and
   verifies end-to-end before moving on.
3. On your laptop, the one command prompts for the **project dir** (a readline prompt that defaults
   to the current dir; press Enter to accept, or type/​create another path).
4. sshfs-mounts it onto an **empty** box dir (your invoking cwd if empty, else `~/work/<project>`)
   and **auto-launches** the agent there (no manual restart) — so the project's CLAUDE.md/AGENTS.md
   load in a fresh session.

Re-run any time to re-verify / remount; everything is idempotent (a stale mount from a dropped
tunnel is detected and replaced on the next run).

## Files

```
remote-harness/
├── SKILL.md                 # the workflow the agent follows (source of truth)
├── manage.sh                # install (copy / --dev symlink) / --uninstall, per agent
├── adapters/
│   ├── codex.md             # → ~/.codex/prompts/remote-harness.md
│   └── opencode.md          # → ~/.config/opencode/command/remote-harness.md
└── scripts/                 # deterministic logic (KEY=VALUE stdout), agent-agnostic
    ├── preflight.sh         # ONE-SHOT prereq check (env+tunnel+sshfs+empty dir) → ok / blocked
    ├── detect.sh            # read-only environment probe
    ├── setup-tunnel.sh      # write remote ssh alias; emit laptop RemoteForward line + pubkey
    ├── connect-guesses.sh   # guess how the laptop connects (for the Step-1 confirm prompt)
    ├── box-identity.sh      # box identity anchors (host-key fps) — laptop-setup inference fallback
    ├── laptop-setup.sh      # RUNS ON LAPTOP: one-shot setup (--host given, or infers as fallback)
    ├── check-tunnel.sh      # verify listener + real ssh login through the tunnel
    ├── list-projects.sh     # list candidate dirs (--via <alias> => scan the laptop)
    ├── mount-project.sh     # sshfs-mount a laptop dir onto your (empty) project dir / --unmount
    └── inject-rule.sh       # RUNS ON BOX: per-session "run builds/tests on the laptop" rule (+opencode yolo)
```

## The mounted-code rule

The agent runs on the box but the code is an sshfs mount of your laptop, so the box often lacks
the project's toolchain — and anything written into the mount (node_modules, .venv, target/…) goes
back to the laptop and may be built for the wrong OS/arch. Before launch, `inject-rule.sh on` builds
**per-session** artifacts on the box and points only this launch at them — **scoped to this session,
never global and never in the mounted repo**, so other projects running on the same box are
unaffected:

| agent | channel (session-scoped) |
|-------|--------------------------|
| claude   | `--append-system-prompt-file <rule>` (session flag) |
| opencode | `OPENCODE_CONFIG=<session config>` (instructions; + `permission:"allow"` when `--yolo`) |
| codex    | `CODEX_HOME=<session home>` (your real auth/config symlinked; our `AGENTS.md` as global guidance) |

The rule tells the agent to run builds, tests, linters, **and dependency installs** on the laptop
via `ssh <box-alias> 'cd <laptop-path> && <cmd>'`, warns **not** to install/build on the box, and
lists stack-tailored example commands (npm/pnpm/cargo/go/pytest/make…) sniffed from the project's
manifests. On exit `inject-rule.sh off` just removes the session dir — nothing to restore.

## Doing it by hand (reference)

```sshconfig
# LAPTOP ~/.ssh/config — add to the Host block you already use (don't change your login Port):
Host my-remote-box
    HostName ...            # unchanged
    Port ...                # unchanged
    RemoteForward 29222 127.0.0.1:22
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

```sshconfig
# REMOTE BOX ~/.ssh/config:
Host laptop
    HostName 127.0.0.1
    Port 29222
    User <your-laptop-username>
    IdentityFile ~/.ssh/id_ed25519
    UserKnownHostsFile ~/.ssh/known_hosts_laptop
    StrictHostKeyChecking accept-new
    ControlMaster auto                       # multiplex: keep one warm connection so
    ControlPath ~/.ssh/cm-%C                  # repeated ssh / sshfs to the laptop are snappy
    ControlPersist 5m                        # (%C is a short hash — avoids macOS's socket-path limit)
```

```bash
# REMOTE BOX — mount a laptop project as your project dir, then launch Claude Code IN it:
sudo apt-get install -y sshfs                  # once
mkdir -p ~/work/myproj && cd ~/work/myproj     # an EMPTY dir dedicated to this project
sshfs laptop:/Users/me/myproj ~/work/myproj \
    -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks,idmap=user
claude                                         # launch in the mount → its CLAUDE.md/.claude load
# (Claude Code reads CLAUDE.md, not AGENTS.md: `printf '@AGENTS.md\n' > CLAUDE.md` or run /init)
# when done:  fusermount -u ~/work/myproj
```

Pick a tunnel port **below** the ephemeral range (`cat /proc/sys/net/ipv4/ip_local_port_range`)
and **different from your login port** — the skill auto-selects the highest free port ending in
`22` (e.g. 32722). On the laptop, fully reconnect (kill any multiplexed master with
`ssh -O exit my-remote-box` first).

## Troubleshooting

- `ssh <host>` suddenly asks for a **password** → wrong sshd (often a missing `Port`). Check
  `ssh -G <host> | grep -E '^(hostname|port)'` and the server host-key fingerprint.
- **Tunnel not up after reconnect** → client reused a multiplexed master. `ssh -O check/exit
  <host>`, close old terminals, reconnect; confirm `ssh -G <host> | grep -i remoteforward`.
- Only the **first** session to a host binds the forward port; the holder must close before a
  new port takes over. Don't add `ExitOnForwardFailure yes` (breaks extra sessions).
- **Mount stalls / "Transport endpoint is not connected"** → the tunnel dropped (laptop slept
  / disconnected). `fusermount -u <mountpoint>`, reconnect from the laptop, re-mount.
- **Project's CLAUDE.md/AGENTS.md not taking effect** → mount onto an **empty** project dir
  and **(re)launch** Claude Code there; it loads CLAUDE.md only at startup and reads CLAUDE.md,
  not AGENTS.md (import via `@AGENTS.md` or run `/init`).

## Security note

If the remote box's sshd is internet-exposed, once key login is confirmed disable password
auth: `PasswordAuthentication no` + `PermitRootLogin prohibit-password`, `sshd -t`, restart.
Verify key login first so you don't lock yourself out.
