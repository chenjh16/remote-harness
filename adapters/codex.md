Run the **remote-harness** workflow.

Goal: set up a reverse SSH tunnel from this remote development machine back to my laptop
(so this machine can `ssh` to my laptop, through NAT), then help me choose a project
directory on this machine and drop me into it to start vibe coding.

Follow the step-by-step instructions in `~/.remote-harness/SKILL.md` exactly. The helper
scripts referenced there live in `~/.remote-harness/scripts/`. Parse each script's
`KEY=VALUE` stdout. Whenever a step needs information or a decision from me, ask me
directly and wait for my answer before continuing. Do not skip the end-to-end
verification step (`check-tunnel.sh`).
