# Issue 1 — reverse-tunnel port (and alias) conflicts on a shared box account

> Chinese counterpart: [issue1.cn.md](issue1.cn.md).

## Symptom

When one server account is logged into by **several real users** at once, and each runs the
remote-harness **reverse** flow to their own laptop, their reverse tunnels collide: the
`RemoteForward <PORT> 127.0.0.1:22` port clashes, and — more dangerously — the box-side ssh alias
gets cross-wired so one user's builds/commits run against **another user's laptop**.

This is **reverse-specific**. In forward, each user runs the agent on their *own* machine and edits
their *own* `~/.ssh/config`; the shared server is only read over sshfs + `ssh server 'cd … && build'`,
so there is no shared per-user state to collide. In reverse, every real user shares one box account,
so all box-side state lives under a single `$HOME`.

## Where the conflicts come from (pre-fix)

1. **The reverse port.** `detect.sh` handed every concurrent user the *same* `SUGGESTED_PORT`
   ("highest free port ending in 22"). Before either tunnel is up, both laptops try to bind the same
   port; the loser's `ssh -N` dies on `ExitOnForwardFailure yes`.
2. **The box-side alias name — the dangerous one.** `BOX_ALIAS` defaulted to `<laptop-user>-mac`.
   Two users whose laptop usernames coincide (`ubuntu`, `user`, a shared corp name) both write
   `Host <name>-mac` into the **shared** `~/.ssh/config` — a single managed block, so whoever runs
   setup last repoints it. The injected rule literally runs `ssh <alias> 'cd <path> && build/commit/
   push'`, so a repointed alias means **cross-user code execution + data leak**.
3. **Default mountpoint + session dir.** Default `<HOME>/work/<project>`; same shared `$HOME` + same
   project name → same mountpoint → second mount hits `not-empty`, and `inject-rule.sh`'s
   per-mountpoint session dir collides too.
4. **`~/.ssh/config` read-modify-write race.** `setup-tunnel.sh` did backup→awk→mv with no lock;
   concurrent runs on the shared account could lose updates.
5. **`known_hosts_<alias>`** keyed by the shared alias name → host-key mismatch noise (a symptom
   of #2).

## The three ideas considered

- **Launch-dir → real username (primary).** With the soft `~/<name>/…` convention, the first path
  component of `$PWD` under `$HOME` is unique per real user. Caveat: it can be a generic dir
  (`work`/`src`) or the cwd may be `$HOME` itself, so it must *pre-fill a confirmation*, never
  auto-decide.
- **Key comment → identity (secondary).** The precise box-side signal of "which laptop" is the
  pubkey that authenticated *this inbound session* — read from the `$SSH_USER_AUTH` file (sshd writes
  the session's auth lines there under `ExposeAuthInfo yes`; the env var holds the file's PATH, not
  its content) and matched against `authorized_keys` to read its comment. But that needs
  `ExposeAuthInfo yes` (default off), so it is often unavailable. Good as a pre-fill, not a sole source.
- **Same user, many projects → reuse one rport (correct target).** The tunnel is a property of the
  *(laptop, box-account)* pair, not the project — one `RemoteForward` port carries unlimited sshfs
  mounts. Rule: **port + alias are per-real-user (stable); mountpoint + session are per-project.**

## The fix (implemented)

Introduce a confirmed **per-real-user namespace `RU`** and thread it through the alias + port.

- **`detect.sh`** now emits `REALUSER_GUESS` / `REALUSER_SOURCE`
  (`authkey|cwd|authorized_keys|none`) / `REALUSER_CANDIDATES`, derived (in priority order) from the
  session auth-key **full comment** (e.g. `alice@macbook` — the most unique per-machine identity; its
  friendlier local part `alice` is offered as an alternative candidate) → first launch-dir component
  under `$HOME` (skipping generic names) → authorized_keys guess. `SUGGESTED_PORT` is now hashed from
  `REALUSER_GUESS` to a **stable `.22` slot in `[20022, 29922]`** (below the ephemeral floor) and
  free-probed, so different users land on different ports and the same user reconnects to the same
  port; it falls back to the legacy "highest free `.22`" when there is no namespace.
- **Confirmation (Step 0a in `reference/reverse.md`).** The agent asks the user to confirm `RU`
  (pre-filled with `REALUSER_GUESS`, offering the candidates + free-form). This is the one new
  required confirmation — added to SKILL.md's "Confirm, don't infer" list.
- **`setup-tunnel.sh`** takes `--namespace <RU>` and, when `--port` is omitted, derives the stable
  port from `RU` the same way `detect.sh` does (formulas kept in sync) and probes for a free slot.
  The box-side alias is `<RU>-mac`. `--port` still wins when given (the runtime port-switch path).
  The shared `~/.ssh/config` edit is now `flock`-serialized (best-effort: flock → mkdir spin-lock →
  unlocked) so concurrent setups don't clobber each other's managed block.
- **`preflight.sh`** with `--alias <RU>-mac` considers **only** that namespaced tunnel for reuse, so
  on a shared account it never latches onto another user's loopback alias. `PREFLIGHT=ok` is also the
  **same-user / another-project** reuse path (remount over the existing tunnel — no new port).
- **`laptop-setup.sh` cleanup** refcounts the shared tunnel so same-user multi-project sessions can
  exit in any order. It records the tunnel's `ssh -N` pid in
  `~/.remote-harness/.tunnel-<box>-<port>.pid`, and on exit drops the tunnel **only** when no other
  session's `<RU>-mac:` sshfs mount remains on the box; the last session out kills it via that pid
  file regardless of which session created it. (Without this, the session that *created* the tunnel
  killing it on exit would strand the other projects' mounts.)
- **Mountpoint** is unchanged by design (per the maintainer's call): default to the agent's current
  project dir, validate it is empty/suitable for sshfs, and always offer a typed alternative. The
  `~/<name>/…` convention already namespaces the cwd when followed. The laptop project dir is chosen
  by interactive input.

## Residual limitations

- The namespace is only as good as the confirmation: if two users both accept the *same* generic
  guess as `RU`, their alias/port still collide. The fix is to re-run Step 0a with distinct names;
  the runtime port-switch in `laptop-setup.sh` remains the safety net.
- The hashed range assumes the ephemeral floor is above `29922` (true on default Linux/macOS); if a
  box lowers it below that, `detect.sh`/`setup-tunnel.sh` fall back to the legacy scan.
- Key-comment identity needs sshd `ExposeAuthInfo yes` (default off). It exposes `$SSH_USER_AUTH` —
  the PATH to a temp file holding the session's auth lines (`publickey <type> <base64>`); `detect.sh`
  reads that file, matches the blob against `authorized_keys`, and uses the **full** comment (most
  unique). When off, the launch-dir convention carries the namespace — there is no portable way to
  learn the session's key without that sshd option.
- The shared-tunnel refcount detects other mounts by matching `<RU>-mac:` in the box mount table — a
  **Linux** signal. On a macOS/FUSE-T box the mount source isn't `<alias>:path`, so other mounts can't
  be seen and the tunnel is dropped on the first exit as before. A tunnel orphaned by a crashed run
  that never wrote its pid file is likewise not auto-reaped (re-running remote-harness rebuilds on the
  same stable port and remounts).
