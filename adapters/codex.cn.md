> 中文版(参考)。功能性提示以英文版 [codex.md](codex.md) 为准。

运行 **remote-harness** 工作流。

目标：将本编程智能体与代码库（分别位于不同机器上）连接起来，让我进入项目进行 vibe-code 开发——构建/测试在托管代码的那台机器上运行。该技能支持**两个方向**，并会自动检测适用方向（然后向我确认）：
- **reverse（反向）** — 你运行在远程主机上，我的代码在我的笔记本电脑（位于 NAT 后）→ 反向 SSH 隧道；
- **forward（正向）** — 你在本地运行，我的代码在可通过 ssh 直接访问的远程服务器上 → 直接挂载。

严格按照 `~/.remote-harness/SKILL.md` 中的分步说明执行（从"Step −1 — pick the direction"开始）。辅助脚本位于 `~/.remote-harness/scripts/`，通过 stdout 输出 `KEY=VALUE`。每当某个步骤需要我提供信息或做出决策时，请直接询问我并等待我的回答后再继续。

**你正在 Codex 中运行** — 因此在输出最终命令时，请传入 `--launch codex`，以启动 Codex（而非 Claude Code）。运行智能体的机器上必须已安装 `codex` CLI。
