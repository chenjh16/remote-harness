> 中文版。英文原版见 [AGENTS.md](AGENTS.md)（以英文版为准）。

# AGENTS.md — 面向在此仓库上工作的编程智能体的指南

本仓库是 **remote-harness** 技能：它可在两种方向上连接分别位于不同机器上的编程智能体与代码库，并向用户提供一条复制即用的命令来挂载代码并启动智能体。（面向用户的文档：`README.md`；运行时技能规范：`SKILL.cn.md`。）本文件面向正在*开发* remote-harness 本身的智能体。

> `CLAUDE.md` 是指向本文件的符号链接，Claude Code 将以此加载；Codex/opencode 则原生读取 `AGENTS.md`。

## 仓库结构

- `SKILL.md` — 精简的技能入口（概述、交互规则、方向选择）。**渐进式披露**：每个方向的流程及脚本契约位于 `reference/` 下。
- `reference/{reverse,forward,scripts}.md` — 详细流程与辅助脚本契约，由智能体在运行时按需通过 `$RH/reference/<file>.md`（`RH=${RH_HOME:-$HOME/.remote-harness}`）读取。
- `scripts/*.sh` — 确定性辅助脚本（stdout 输出 `KEY=VALUE`，stderr 输出说明信息）。`_common.sh` 是被 source 的公共库（非入口脚本）。`laptop-setup.sh`（reverse 方向）/ `local-setup.sh`（forward 方向）是编排器；`mount-project.sh`、`inject-rule.sh`、`list-projects.sh` 两个方向共用。
- `adapters/{codex,opencode}.md` — 各智能体专属说明。`opencode.md` 装成 opencode 的自定义命令；`codex.md` 仅供参考（Codex 没有自定义斜杠命令，所以 manage.sh 把共享的 `SKILL.md` 作为 Codex 原生**技能**装到 `$CODEX_HOME/skills/` 下）。两者都只是告知智能体读取 `SKILL.md` 并传入正确的 `--launch`。
- `manage.sh` — 安装（拷贝）/ `--dev`（符号链接）/ `--uninstall`。将核心安装到 `~/.remote-harness/{SKILL.md,scripts/,reference/}`，并安装三个智能体专属入口文件。

## 两种方向（核心模型）

通用角色定义：**A** = 智能体运行所在机器；**P** = 代码所在机器（通过 ssh `<alias>` 访问）。
- **reverse**：A = 远程主机，P = 位于 NAT 后的笔记本 → 反向 SSH 隧道；由运行在笔记本上的 `laptop-setup.sh` 编排。
- **forward**：A = 本地机器，P = 可直接 ssh 访问的服务器 → 直接 ssh；由本地运行的 `local-setup.sh` 编排。
两种方向均：将 P 上的项目通过 sshfs 挂载到 A 上的空目录，通过 `inject-rule.sh` 注入"在 `<alias>` 上构建"规则，并在挂载目录中启动智能体。

## 不变量 — 不得破坏

1. **`laptop-setup.sh` 必须能够独立运行。** 在 reverse 方向中，它会被下载到笔记本（笔记本上没有安装）后在那里执行。它通过 `. "$(dirname "$0")/_common.sh"` source `_common.sh`，因此生成的一条命令会将两个文件一并下载到同一个临时目录中。不要添加仅存在于安装目录中的依赖。
2. **始终确认，切勿自动推断。** 方向、代码位置和挂载点必须均为用户的明确选择（自动检测仅用于预填充）。参见 `SKILL.cn.md` 中的"确认，不推断"。
3. **`inject-rule.sh` 与方向无关，且永远不写入已挂载的仓库。** 每次会话的临时文件位于 `$RH_HOME/.sessions/<key>` 下。规则措辞使用 `<alias>` / "this machine"。
4. **将拼接进远程命令的所有值用 `sq()`（来自 `_common.sh`）进行 shell 引号处理** — 路径中可能含有单引号；未加引号的插值存在注入/中断风险。切勿对 `--via` 使用 `eval`。
5. **可移植性**：目标平台为 Linux、WSL 和 macOS。使用 `#!/usr/bin/env bash`；避免 GNU 专属标志（提供 BSD 回退方案）；端口监听检查顺序为 `ss → netstat -an → lsof`；sshfs 安装提示应感知操作系统；**macOS 使用 FUSE-T（无需内核扩展），绝不使用 macFUSE**。探针脚本使用 `set -uo pipefail`（不用 `-e`）以保证持续输出。
6. **脚本在 stdout 输出 `KEY=VALUE`，在 stderr 输出人类可读说明。** 保持该契约不变，消费方依赖解析它。

## 约定

- **双语文档（必须）：** 每份 Markdown 文档必须有一个命名为 `<name>.cn.md` 的中文对应版本（中文为主要受众）。**例外：** `README.md`（行内双语，中文优先）和 `CLAUDE.md`（符号链接）。新增或编辑任何 `*.md` 时，须在同一次变更中创建/更新对应的 `*.cn.md`，以保持同步。示例：`SKILL.md`→`SKILL.cn.md`，`reference/reverse.md`→`reference/reverse.cn.md`，`adapters/codex.md`→`adapters/codex.cn.md`。
- 保持 `SKILL.md` 精简；将深度内容放入 `reference/`。
- 每个脚本只负责一项职责；通过 `_common.sh` 共享逻辑。

## 开发与测试

- 每次修改后执行 `bash -n scripts/*.sh manage.sh`（语法检查门控）。
- 在沙盒 `HOME`/`RH_HOME` 中对各部分进行空跑（例如 `inject-rule.sh on … ; off …`；`preflight.sh --direction forward`；`mount-project.sh --unmount`）。验证在修改 `_common.sh` 时 reverse 模式生成的 managed-alias 输出保持不变。
- Forward 回环端到端测试：向 `localhost` 添加一个 ssh 别名，运行 `local-setup.sh --via … --remote-path … --mountpoint /tmp/… --launch claude`；确认挂载、规则注入及退出时的卸载均正常。
- 完整的双主机端到端测试（从远程主机 reverse / forward 到服务器，包括 macOS FUSE-T）为手动测试。
- 本仓库为仅本地使用的 `main` 分支仓库；仅在被要求时提交。
