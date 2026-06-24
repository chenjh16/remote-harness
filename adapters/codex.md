# Codex — installed as a native skill

Codex does not expose custom `/slash` commands for this workflow. `manage.sh codex` installs
remote-harness as a native Codex skill under `$CODEX_HOME/skills/remote-harness` (`CODEX_HOME`
defaults to `~/.codex`).

Invoke it with:

```text
$remote-harness
```

Codex should read `SKILL.md` and return the right simple bootstrap command immediately. Do not ask
for SSH targets, paths, ports, or namespaces in chat; the command will prompt for them in the user's
local terminal. Use simple reverse by default; use simple forward when the user explicitly asks for
local Codex with a project/dev environment on an SSH server.
The setup scripts use session-local SSH config files and wrappers under `~/.remote-harness`.
Mention `~/.ssh` edits only for the reverse-mode `authorized_keys` temporary managed block; do not
imply that config, known_hosts, or SSH keys are edited.

Because this adapter is for Codex, the emitted command must use:

```bash
--launch codex
```

If the user asks for yolo / bypass approvals, append `--yolo`.

> Tip: `./manage.sh --dev codex` symlinks `$CODEX_HOME/skills/remote-harness` to this repo. Restart
> Codex after changing installed skills; a running TUI may keep the previous skill inventory.
