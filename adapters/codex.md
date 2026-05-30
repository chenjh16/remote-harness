Run the **remote-harness** workflow.

Goal: set up a reverse SSH tunnel from this remote development machine back to my laptop
(so this machine can `ssh` to my laptop, through NAT). My project lives on the LAPTOP — the
flow then hands me one command to run on my laptop that sshfs-mounts my chosen laptop project
onto this box and starts vibe coding here, editing those laptop files locally.

Follow the step-by-step instructions in `~/.remote-harness/SKILL.md` exactly. The helper
scripts referenced there live in `~/.remote-harness/scripts/`. Parse each script's
`KEY=VALUE` stdout. Whenever a step needs information or a decision from me, ask me
directly and wait for my answer before continuing.

**You are running in Codex** — so when you emit the laptop command (SKILL.md Step 1c), pass
`--launch codex` so the remote box starts Codex (not Claude Code). The remote must have the
`codex` CLI installed.
