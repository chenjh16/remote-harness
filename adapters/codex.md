# Codex — installed as a native skill (no slash command)

codex-cli does **not** expose custom `/slash` commands: its TUI slash list only enumerates built-in
and service-tier commands, and plugin `commands/` are not loaded into the TUI. So `manage.sh codex`
installs remote-harness as a **native Codex skill** — it places the shared `SKILL.md` at
`$CODEX_HOME/skills/remote-harness/SKILL.md` (`CODEX_HOME` defaults to `~/.codex`).

**Invoke it by typing `remote-harness`** (no leading slash) — or just describe the task; Codex's skill
trigger rules match on the skill name/description. Codex then opens `SKILL.md`; follow it from
"Step −1 — pick the direction". Whenever a step needs information or a decision from the user, ask in
chat and wait for the reply before continuing.

**You are running in Codex** — so when you emit the final command, pass `--launch codex` so it starts
Codex (not Claude Code). The machine the agent runs on must have the `codex` CLI installed.

> Tip (keep it updatable): instead of `manage.sh`, you can `git clone` this repo into
> `$CODEX_HOME/skills/remote-harness` and `git pull` to update, then point
> `~/.remote-harness/{scripts,reference,SKILL.md}` at that clone — one `git pull` refreshes both the
> skill and the helper scripts.
