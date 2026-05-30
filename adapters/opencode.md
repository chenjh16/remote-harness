---
description: Reverse-SSH tunnel back to your laptop, then mount a laptop project here to vibe-code in
---

Run the **remote-harness** workflow.

Read `~/.remote-harness/SKILL.md` and follow it step by step; the helper scripts are in
`~/.remote-harness/scripts/` and emit `KEY=VALUE` lines on stdout. The goal is to open a
reverse SSH tunnel from this remote dev machine back to my laptop; my project lives on the
LAPTOP, so the flow then hands me one command to run on my laptop that sshfs-mounts my chosen
laptop project onto this box and starts vibe coding here.

Ask me for any required input and wait for my reply before proceeding.

**You are running in opencode** — so when you emit the laptop command (SKILL.md Step 1c), pass
`--launch opencode` so the remote box starts opencode (not Claude Code). The remote must have
the `opencode` CLI installed.
