# Forward direction — agent local, code on a directly-reachable remote server

You (the agent) run on the user's LOCAL machine; the project lives on a remote server the machine
can ssh to directly. No tunnel — everything runs locally + direct ssh, so the skill and the emitted
command both run on THIS machine. Keep the same continuous, question-tool-gated flow (honor the
**"Confirm, don't infer"** rule and cross-agent question tool policy from SKILL.md); the only
legitimate stops are an sshfs-install gate and the final hand-off. Helper-script contracts:
`$RH/reference/scripts.md`.

**Speed: ask, don't fish.** This must be fast — a few questions and the local command is ready.
**Never scan the server to discover the project** (no `list-projects.sh --via`, no `ssh <server>
'find …'`): it's slow and low-value. The user **types** the server project path; recommend only from
cheap signals — the per-server cache (`session-cache.sh`), `~/.ssh/config`, `server-guesses.sh` — and
always offer a typed "Other". The mount validates the path; a wrong one just re-prompts.

## F-0 — Preflight (local)

```bash
"$RH/scripts/preflight.sh" --direction forward --no-list
```
- `BLOCKED_STEP=sshfs` → show the OS-aware `REMEDY`, AskUserQuestion ("installed? ✅/⚠️"), re-run on
  ✅. Loop until `PREFLIGHT=ok`. (`PROJECT_DIR_EMPTY` = the LOCAL cwd; decides the mountpoint in F-2.5.)

## F-1 — Pick the server (how you ssh to it)

```bash
"$RH/scripts/server-guesses.sh"   # candidate `ssh <target>` lines (config aliases / known_hosts / history)
```
**AskUserQuestion**: "Which server hosts your project (how do you ssh to it)?"
- Claude/chat may show the useful guesses directly. Codex structured input must offer only the best
  2-3 guesses (e.g. `ssh myserver`, `ssh dev@10.0.0.5`); the client-provided Other/free-form answer
  remains the place for the real command, e.g. `ssh -p 2222 dev@server.example.com`.
- Extract `CONNECT` = ssh args without the leading `ssh` (e.g. `myserver`, or `-p 2222 dev@host`).
- Supported raw `CONNECT` forms are a host/alias, optional `user@host`, `-p`/`-l`/`-i`, and `-J` /
  `-o ProxyJump=...` with tokens that do not need shell quoting. For complex SSH behavior
  (`ProxyCommand`, `-F`, quoted paths with spaces, local forwards, etc.), tell the user to put that
  in `~/.ssh/config` as a `Host` alias and provide the alias.

## F-2 — Pick the project dir on the server (type it; don't scan)

```bash
"$RH/scripts/session-cache.sh" get "<SERVER_TOKEN>"                            # LAST_PROJECT_DIR/LAST_MOUNTPOINT (empty on first run)
"$RH/scripts/preflight.sh" --direction forward --server '<CONNECT>' --no-list  # reachability ONLY — no project scan
```
- `SERVER_REACHABLE=0` → help fix ssh/keys (they may just be prompted for a password — warn the
  session won't be non-interactive), then re-run. Do NOT end the turn.
- **AskUserQuestion**: "Which project directory on the server?" Pre-fill `LAST_PROJECT_DIR` if cached;
  otherwise the user **types the absolute server path** (e.g. `/srv/app`) via Other. Do NOT scan the
  server (`list-projects.sh` / `ssh … find`) — it's slow and low-value; the typed path is validated
  when the mount runs. → `REMOTE_PROJECT_DIR`. (`<SERVER_TOKEN>` = the `HOST`/alias token from F-1,
  used as the cache key.)

## F-2.5 — Confirm the local mountpoint (required)

**AskUserQuestion** "Where on THIS machine should the project mount and the agent launch?"
(pre-fill `LAST_MOUNTPOINT` from the cache if present and still empty):
- "Here: `<cwd>` (my current dir)" — only if empty (`PROJECT_DIR_EMPTY=1`); pre-select when empty.
  → pass `--mountpoint '<cwd>'`.
- "A fresh `~/remote-harness-mounts/<name>` dir (auto)" — pre-select when the cwd is non-empty.
  → OMIT `--mountpoint`.
- Other (a different EMPTY local dir) → pass `--mountpoint '<that dir>'`.

## F-3 — Emit the local command — then you are done

Use the `<LOCAL_MP>` (and whether to pass `--mountpoint`) decided in **F-2.5**, and the
`<REMOTE_PROJECT_DIR>` from **F-2** — both user-confirmed, not guessed.

Before emitting, remember the choices so a re-run for this server pre-fills instantly:

```bash
"$RH/scripts/session-cache.sh" put <SERVER_TOKEN> \
  "LAST_PROJECT_DIR=<REMOTE_PROJECT_DIR>" "LAST_VIA=<CONNECT>" \
  "LAST_MOUNTPOINT=<LOCAL_MP>" "LAST_LAUNCH=<LAUNCH>"
```

Print **exactly** (short, `\`-continued lines):

```
"$HOME/.remote-harness/scripts/local-setup.sh" \
  --via <CONNECT_Q> --remote-path <REMOTE_PROJECT_DIR_Q> \
  [--mountpoint <LOCAL_MP_Q>] --launch <LAUNCH> [--yolo]
```
- `<LAUNCH>` = the CLI of the agent you are running in (claude/codex/opencode).
- `[--yolo]` only if the user asked to bypass approvals.
- Every `<..._Q>` placeholder is a shell word quoted with `sq()` semantics. Example:
  `/srv/O'Neil/app` becomes `'/srv/O'\''Neil/app'`. Apply this to `--via`, `--remote-path`, and
  `--mountpoint`.

Tell the user:

> Run this **in a fresh local terminal** (the agent will take over that terminal). It will:
> 1. Ensure a stable ssh alias to your server (writing a `<host>-dev` alias if you gave raw args)
> 2. sshfs-mount the server's project onto a local dir
> 3. Launch the agent there — builds/tests run on the server (`ssh <alias> ...`), your edits are live
>
> When you exit, the mount is removed automatically. Start remote-harness again to reconnect
> (`/remote-harness` in Claude Code/opencode, `$remote-harness` in Codex).

**Your turn ends here** — `local-setup.sh` is self-contained and interactive on the local side.

### Troubleshooting (forward)
- **Prompted for a password** (sshfs/builds) → set up an ssh key to the server; the managed
  `<host>-dev` alias will then be non-interactive. Until then the session prompts.
- **`not-empty`** → the chosen local mountpoint isn't empty; the script prompts for another (or pass
  `--mountpoint <empty-dir>`).
- **macOS sshfs without macFUSE** → the mount step surfaces a **no-kext** install
  (`brew install macos-fuse-t/homebrew-cask/fuse-t && brew install macos-fuse-t/homebrew-cask/sshfs-fuse-t`)
  and retries after you install it. FUSE-T needs **no kernel extension and no reduced system
  security**, and keeps sshfs's synchronous writes (so edits land on the server before remote
  builds). Avoid macFUSE (it requires lowering security).
  - *Fallback if FUSE-T misbehaves:* `rclone` (`brew install rclone`, configure an sftp remote, then
    `rclone nfsmount remote:/path <mp> --vfs-cache-mode full --vfs-write-back 0`) — also kext-less,
    but writes are **asynchronous**, so an edit immediately followed by a remote build may briefly
    see the old file. Prefer FUSE-T for this skill's edit-here / build-on-server loop.
