# Codex — installed as a native skill (no slash command)

codex-cli does **not** expose custom `/slash` commands: its TUI slash list only enumerates built-in
and service-tier commands, and plugin `commands/` are not loaded into the TUI. So `manage.sh codex`
installs remote-harness as a **native Codex skill** under `$CODEX_HOME/skills/remote-harness`
(`CODEX_HOME` defaults to `~/.codex`). Copy install places `SKILL.md` there; dev install symlinks the
whole skill directory to this repo so Codex sees the same shape as a normal skill directory.

**Invoke it by typing `$remote-harness`** (for example, `$remote-harness yolo模式，中文`). This is the
direct Codex skill invocation form. Plain `remote-harness` or a natural-language request may also
trigger by skill name/description, but `$remote-harness` is the explicit form to document. Codex then opens `SKILL.md`; follow it from
"Step −1 — pick the direction". Whenever a step needs information or a decision from the user, ask in
the most interactive way this Codex session supports:

- If the `request_user_input` tool is listed and available for the current collaboration mode, use it
  for required choices (direction, project dir, mountpoint, sshfs retry). It waits for the user's
  response and supports the free-form `Other` path.
- If the tool is absent or Codex reports it is unavailable, ask in chat and wait for the reply before
  continuing. This is the expected fallback in Default mode unless `default_mode_request_user_input`
  is enabled.

Do not emit the final command until every required choice has an explicit user answer.

Optional: Codex builds that expose the `default_mode_request_user_input` feature can show the
structured picker in Default mode too:

```bash
codex features enable default_mode_request_user_input
```

**You are running in Codex** — so when you emit the final command, pass `--launch codex` so it starts
Codex (not Claude Code). The machine the agent runs on must have the `codex` CLI installed.

> Tip (keep it updatable): `./manage.sh --dev codex` symlinks
> `$CODEX_HOME/skills/remote-harness` to this repo. Restart Codex after changing installed skills;
> an already-running TUI may keep the previous skill inventory.
