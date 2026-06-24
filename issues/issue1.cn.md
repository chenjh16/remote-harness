> 中文版。英文原版见 [issue1.md](issue1.md)（以英文版为准）。

# Issue 1 — 共享账号下的反向隧道冲突

## 状态

当前 simple 流程已解决。

早期 reverse 设计会把 `<user>-mac` 这类盒子侧 alias 写入共享账号的 `~/.ssh/config`。在多人共用同一个
服务器账号时，真实用户可能在 alias 名、反向端口和 `known_hosts_<alias>` 文件上互相覆盖，导致某个用户
注入规则里的 `ssh <alias> ...` 连到另一个用户的笔记本。

当前 simple 实现通过会话级 SSH config 避免这类问题：

- reverse 盒子 -> 笔记本 alias：远端 `~/.remote-harness/.sessions/.../ssh_config`；
- reverse 笔记本 -> 盒子 RemoteForward alias：本地 `~/.remote-harness/.sessions/.../ssh_config`；
- forward raw args 服务器 alias：本地 `~/.remote-harness/.sessions/.../ssh_config`。

它不会创建、修改、备份、追加或清理 `~/.ssh/config`、`known_hosts`、SSH key、
`config.rh-bak.*` 或 `known_hosts_<alias>`。唯一有意的 `~/.ssh` 修改是 simple reverse 中笔记本侧
用于临时反向认证的 `authorized_keys` 托管块。

## 仍然共享的状态

- 反向 key 生成使用 `$RH_HOME/keys/id_ed25519`，不是 `~/.ssh`。simple reverse 可以自动生成/复用这把
  key，并在笔记本侧用带标签、仅限回环来源的 `authorized_keys` 托管块临时授权其公钥。
- 反向隧道监听端口仍是远端账号资源。`laptop-setup.sh` 会验证已有监听是否真的连回本笔记本；
  若不是，会切换到附近空闲端口。
- 已存在的历史 `~/.ssh/config` block 或 `known_hosts_*` 文件不会自动删除；它们属于用户遗留状态。
  只有用户明确要求时才做清理。

## 设计规则

所有新的 simple-flow 工作都必须让 alias、host-key 状态和 ControlPath socket 保持在
`~/.remote-harness/.sessions` 会话级目录中。不要为了方便重新引入更广泛的 `~/.ssh` 写入；需要时使用内部
ssh wrapper，或把 `--ssh-config` 传给对应 helper。
