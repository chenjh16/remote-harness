---
description: Connect this agent to a codebase on another machine (remote box↔laptop, or local↔remote server) and vibe-code
---

Run the **remote-harness** workflow.

Read `~/.remote-harness/SKILL.md` and follow it step by step (start at "Step −1 — pick the
direction"); the helper scripts are in `~/.remote-harness/scripts/` and emit `KEY=VALUE` on stdout.
Goal: connect this agent and my codebase (on different machines) and drop me into the project, with
builds/tests on whichever machine hosts the code. The skill always asks which direction
first (pre-selecting a likely default, but never deciding for me): **reverse** = you're on a remote box, code on my laptop behind NAT (reverse tunnel);
**forward** = you're local, code on a remote server I ssh to (direct mount).

Ask me for any required input and wait for my reply before proceeding.

**You are running in opencode** — so when you emit the final command, pass `--launch opencode` so it
starts opencode (not Claude Code). The machine the agent runs on must have the `opencode` CLI installed.
