Run the **remote-harness** workflow.

Goal: connect this coding agent and my codebase, which live on different machines, and drop me into
the project to vibe-code — with builds/tests running on whichever machine hosts the code. The skill
works in EITHER direction and always asks me which one applies first (pre-selecting a likely
default, but never deciding for me):
- **reverse** — you're on a remote box, my code is on my laptop (behind NAT) → reverse SSH tunnel;
- **forward** — you're running locally, my code is on a remote server I ssh to → direct mount.

Follow the step-by-step instructions in `~/.remote-harness/SKILL.md` exactly (start at "Step −1 —
pick the direction"). The helper scripts live in `~/.remote-harness/scripts/` and emit `KEY=VALUE`
on stdout. Whenever a step needs information or a decision from me, ask me directly and wait for my
answer before continuing.

**You are running in Codex** — so when you emit the final command, pass `--launch codex` so it
starts Codex (not Claude Code). The machine the agent runs on must have the `codex` CLI installed.
