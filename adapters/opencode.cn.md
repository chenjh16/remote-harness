> 中文版(参考)。功能性命令以英文版 [opencode.md](opencode.md) 为准。

---
description: 将此代理连接到另一台机器上的代码库（远程主机↔笔记本，或本地↔远程服务器）并进行 vibe 编程
---

运行 **remote-harness** 工作流。

读取 `~/.remote-harness/SKILL.md` 并逐步执行（从"Step −1 — pick the
direction"开始）；辅助脚本位于 `~/.remote-harness/scripts/`，会在 stdout 输出 `KEY=VALUE`。
目标：将此代理与我的代码库（分布在不同机器上）连接起来，并进入项目目录，
构建/测试在托管代码的那台机器上运行。技能会自动检测方向（并确认）：
**reverse** = 你在远程主机上，代码在我的笔记本上（NAT 后方，反向隧道）；
**forward** = 你在本地，代码在我可以 ssh 到的远程服务器上（直接挂载）。

如需任何必要输入，请询问我并等待我的回复后再继续。

**你正在 opencode 中运行** — 因此在输出最终命令时，请加上 `--launch opencode`，
以便启动 opencode（而非 Claude Code）。运行代理的机器上必须已安装 `opencode` CLI。
