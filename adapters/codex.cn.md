> 中文版(参考)。功能性提示以英文版 [codex.md](codex.md) 为准。

# Codex —— 以原生技能方式安装(无斜杠命令)

codex-cli **不支持**自定义 `/` 斜杠命令:其 TUI 的 `/` 列表只枚举内置命令和 service-tier 命令,插件的
`commands/` 也不会加载进 TUI。因此 `manage.sh codex` 会把 remote-harness 装成
**Codex 原生技能**，位置是 `$CODEX_HOME/skills/remote-harness`（`CODEX_HOME` 默认为
`~/.codex`）。复制安装会把 `SKILL.md` 放进去；开发安装会把整个 skill 目录软链到本仓库，让 Codex 看到的结构和普通 skill 目录一致。

**调用方式:直接输入 `$remote-harness`**（例如 `$remote-harness yolo模式，中文`）。这是 Codex
直接调用技能的显式形式。纯 `remote-harness` 或自然语言请求也可能按技能名/描述触发，但文档中应优先写 `$remote-harness`。随后 Codex 会打开 `SKILL.md`,从「Step −1 — pick the direction」开始照做。每当某步
需要用户提供信息或做决策时,使用当前 Codex 会话支持的最强交互方式:

- 如果工具列表中有 `request_user_input`,且它在当前协作模式下可用,则用它确认必选项（方向、项目目录、挂载点、sshfs 重试）。该工具会等待用户回答,并支持自由输入的 `Other` 路径。
- 如果该工具不存在,或 Codex 报告它不可用,则在聊天中提问并等待回答后再继续。在未启用 `default_mode_request_user_input` 的 Default mode 中,这是预期退化路径。

在每个必须选择的项目都收到用户明确答复之前,不要输出最终命令。

可选:如果你的 Codex 版本暴露了 `default_mode_request_user_input` 功能,可以让 Default mode 也显示结构化选择器:

```bash
codex features enable default_mode_request_user_input
```

**你正在 Codex 中运行** —— 因此在输出最终命令时,请传入 `--launch codex`,以启动 Codex(而非
Claude Code)。运行智能体的机器上必须已安装 `codex` CLI。

> 提示(便于更新):`./manage.sh --dev codex` 会把 `$CODEX_HOME/skills/remote-harness` 软链到本仓库。
> 修改已安装技能后请重启 Codex；已经运行的 TUI 可能保留旧的 skill 列表缓存。
