> 中文版（参考）。功能性命令以英文版 [opencode.md](opencode.md) 为准。

---
description: 通过 remote-harness simple 工作流将此 Agent 连接到另一台机器上的项目
---

运行 **remote-harness** simple 工作流。

读取 `~/.remote-harness/SKILL.md` 并立即返回 bootstrap 命令。不要在聊天中询问 SSH target、路径、端口或命名空间；这些信息会由命令在用户本地终端里提示输入。默认使用 simple reverse；当用户明确要求本地 Agent 连接 SSH 服务器上的项目/开发环境时，使用 simple forward。
setup 脚本使用 `~/.remote-harness` 下的会话级 SSH config 和 wrapper。只有 reverse 模式下
`authorized_keys` 临时托管块需要提到 `~/.ssh` 修改；不要暗示会编辑 config、known_hosts 或 SSH key。

因为这是 opencode 适配入口，输出命令必须使用：

```bash
--launch opencode
```

如果用户要求 yolo / bypass approvals，则追加 `--yolo`。
