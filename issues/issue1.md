# Issue 1 — shared-account reverse tunnel conflicts

> Chinese counterpart: [issue1.cn.md](issue1.cn.md).

## Status

Resolved for the current simple flows.

Earlier reverse designs wrote box-side aliases such as `<user>-mac` into a shared account's
`~/.ssh/config`. On a shared server account, two real users could collide on alias names, reverse
ports, and `known_hosts_<alias>` files. That could make one user's injected `ssh <alias> ...`
commands reach another user's laptop.

The current simple implementation avoids that class of bugs by using session-local SSH config files:

- reverse box -> laptop alias: remote `~/.remote-harness/.sessions/.../ssh_config`;
- reverse laptop -> box RemoteForward alias: local `~/.remote-harness/.sessions/.../ssh_config`;
- forward raw-args server alias: local `~/.remote-harness/.sessions/.../ssh_config`.

It does not create, modify, back up, append to, or clean up `~/.ssh/config`, `known_hosts`, SSH keys,
`config.rh-bak.*`, or `known_hosts_<alias>`. The only intentional `~/.ssh` mutation is simple
reverse's laptop-side `authorized_keys` managed block for temporary reverse authentication.

## Remaining Shared State

- Reverse key generation uses `$RH_HOME/keys/id_ed25519`, not `~/.ssh`. The simple reverse flow can
  generate/reuse that key automatically and temporarily authorize its public key on the laptop with
  a tagged, loopback-scoped `authorized_keys` block.
- Reverse tunnel listener ports are still remote account resources. `laptop-setup.sh` validates that
  an existing listener actually reaches this laptop and switches to a nearby free port if not.
- Existing historical `~/.ssh/config` blocks or `known_hosts_*` files are not automatically removed;
  they are user-owned leftovers. Cleanup should be explicit if the user asks for it.

## Design Rule

All new simple-flow work must keep aliases, host-key state, and ControlPath sockets session-local
under `~/.remote-harness/.sessions`. Do not reintroduce broader writes under `~/.ssh` to solve convenience
problems; use an internal ssh wrapper or pass `--ssh-config` to the helper that needs it.
