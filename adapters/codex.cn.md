> 中文版(参考)。功能性提示以英文版 [codex.md](codex.md) 为准。

# Codex —— 以原生技能方式安装(无斜杠命令)

codex-cli **不支持**自定义 `/` 斜杠命令:其 TUI 的 `/` 列表只枚举内置命令和 service-tier 命令,插件的
`commands/` 也不会加载进 TUI。因此 `manage.sh codex` 把 remote-harness 装成 **Codex 原生技能** ——
将共享的 `SKILL.md` 放到 `$CODEX_HOME/skills/remote-harness/SKILL.md`(`CODEX_HOME` 默认为 `~/.codex`)。

**调用方式:直接输入 `remote-harness`**(不带前导斜杠)—— 或直接描述任务;Codex 的技能触发规则会按
技能名/描述匹配。随后 Codex 会打开 `SKILL.md`,从「Step −1 — pick the direction」开始照做。每当某步
需要用户提供信息或做决策时,在对话里直接询问并等待回答后再继续。

**你正在 Codex 中运行** —— 因此在输出最终命令时,请传入 `--launch codex`,以启动 Codex(而非
Claude Code)。运行智能体的机器上必须已安装 `codex` CLI。

> 提示(便于更新):除了用 `manage.sh`,你也可以把本仓库 `git clone` 到
> `$CODEX_HOME/skills/remote-harness`,用 `git pull` 更新;再把
> `~/.remote-harness/{scripts,reference,SKILL.md}` 软链到该 clone —— 一次 `git pull` 同时刷新技能和
> 辅助脚本。
