---
description: Connect this agent to a project on another machine via remote-harness simple workflows
---

Run the **remote-harness** simple workflow.

Read `~/.remote-harness/SKILL.md` and return the bootstrap command immediately. Do not ask for SSH
targets, paths, ports, or namespaces in chat; the command prompts for them in the user's local
terminal. Use simple reverse by default; use simple forward when the user explicitly asks for a local
agent with a project/dev environment on an SSH server.
The setup scripts use session-local SSH config files and wrappers under `~/.remote-harness`.
Mention `~/.ssh` edits only for the reverse-mode `authorized_keys` temporary managed block; do not
imply that config, known_hosts, or SSH keys are edited.

Because this adapter is for opencode, the emitted command must use:

```bash
--launch opencode
```

If the user asks for yolo / bypass approvals, append `--yolo`.
