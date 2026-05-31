---
name: remote-harness
description: >-
  Set up a development harness that connects a coding agent and a codebase living on different
  machines, in EITHER direction. Invoke when the user runs /remote-harness (or types "remote-harness"
  in Codex, which has no slash commands). Reverse: the agent runs
  on a remote box and your code is on your LAPTOP (behind NAT) — builds a reverse SSH tunnel.
  Forward: the agent runs LOCALLY and your code is on a directly ssh-reachable REMOTE server. Either
  way it sshfs-mounts the code onto an empty dir where the agent runs, tells the agent to run
  builds/tests on the machine that hosts the code, and hands you ONE copy-paste command that does
  the rest (mount + launch claude/codex/opencode). Supports Linux/WSL/macOS.
---

# Remote Harness

This file is the lean entry point. Per **progressive disclosure**, it covers the always-needed bits
(what the skill does, the interaction rules, and picking the direction); the detailed per-direction
flow and the helper-script contracts live under `$RH/reference/` — read only the one you need.

## What this skill does

The coding agent and the codebase are on **two different machines**. This skill mounts the code
where the agent runs and launches the agent there, in whichever of two directions applies:

- **Reverse** — the agent runs on a **remote box**; the code is on the user's **laptop** (behind
  NAT). The box can't dial the laptop, so the laptop opens a **reverse SSH tunnel** and the laptop
  project is sshfs-mounted onto the box.
- **Forward** — the agent runs **locally** (laptop/WSL/mac); the code is on a **directly
  ssh-reachable remote server**. No tunnel: the server's project is sshfs-mounted onto a local dir.

In BOTH directions the invariant is the same: sshfs-mount the code onto an **empty** dir where the
agent runs, inject a rule that builds/tests run **on the machine that hosts the code** (via
`ssh <alias>`), and launch the agent (claude/codex/opencode) in the mount. Generically: **A** = the
machine the agent runs on; **P** = the machine the code lives on (referenced by an ssh `<alias>`).

## Interaction — keep the flow continuous

This skill is **one continuous agent-driven flow** from picking the direction to handing over the
final command. Whenever a step needs a user decision or is blocked, use the best interactive input
channel your agent runtime exposes — never skip a required confirmation, and never continue past an
unanswered decision.

> **Confirm, don't infer (REQUIRED).** Detected values — direction, the project/codebase to develop,
> and the mountpoint where the agent will launch — are only DEFAULTS that PRE-FILL a question, never
> final decisions. You MUST get the user's explicit answer for EACH of these three before emitting
> the final command. Auto-detection (e.g. `SSH_CONNECTION` → direction, cwd → mountpoint) only
> pre-selects the likely option; it must NOT skip the question. Never silently assume the user's intent.

> **Cross-agent question tool policy:** wherever the steps say "**AskUserQuestion**", use the
> runtime's structured user-input tool when one is available. Claude Code: use `AskUserQuestion`.
> Codex: if `request_user_input` is listed and available for the current collaboration mode, use it
> for the decision; it waits for the user's answer and may add an `Other` free-form option. If Codex
> says `request_user_input` is unavailable (commonly because the session is in Default mode without
> the `default_mode_request_user_input` feature), fall back to one concise chat question and wait for
> the reply. opencode: ask in chat and wait. For chat fallbacks, batch tightly related decisions
> (up to three) only when doing so reduces round-trips and the expected answer format is obvious.

The **only legitimate places to stop** are:
- `sshfs` blocked: give the install cmd, AskUserQuestion ("installed? ✅/⚠️"), re-run on ✅.
- After handing over the final command: the setup script takes over (self-contained + interactive on
  that machine). **The agent's job is done once it hands the user that command.**

## Invocation options

The user may pass a free-form request when invoking (e.g. `/remote-harness 开启yolo模式`,
`/remote-harness yolo`, "...bypass approvals"). Parse for intent and apply when emitting the command:

- **YOLO / bypass approvals** (any of: "yolo", "bypass approvals", "skip permissions", "危险模式",
  "免审批", "开启yolo模式") → add `--yolo` to the emitted command (the setup script maps it per agent).
  Confirm once if intent is ambiguous; otherwise just apply it. If absent, launch normally.

## References (read on demand)

```bash
RH="${RH_HOME:-$HOME/.remote-harness}"
[ -d "$RH/scripts" ] || echo "scripts missing — run: manage.sh"
```

- Helper-script contracts (KEY=VALUE outputs, `inject-rule.sh`, etc.): **`$RH/reference/scripts.md`**
- **Reverse** flow (preflight → build tunnel → emit the laptop command): **`$RH/reference/reverse.md`**
- **Forward** flow (preflight → pick server/dir → emit the local command): **`$RH/reference/forward.md`**

Parse `KEY=VALUE` from each script's stdout; human notes go to stderr.

---

## Step −1 — Pick the direction (ALWAYS ASK — never decide silently)

**You MUST ask the user which direction, even when you can guess.** Use the cross-agent question tool
policy above — "Where does your code live, relative to where I'm running?":
- **Reverse** — "I'm on a remote box; my code is on my laptop (behind NAT)."
- **Forward** — "I'm running locally; my code is on a remote server I can ssh to."

Use detection ONLY to pre-select the likely option (do NOT skip the question): `SSH_CONNECTION` set
(or `detect.sh` → `ON_REMOTE=1`) ⇒ pre-select **reverse**; unset ⇒ pre-select **forward**. Wait for
the user's explicit answer.

Then **read `$RH/reference/reverse.md` or `$RH/reference/forward.md`** for the chosen direction and
follow it step by step, honoring the "Confirm, don't infer" rule for every choice.
