> 中文版。英文原版见 [design.md](design.md)（以英文版为准）。

# remote-harness — 设计文档

> 本文说明*项目是怎么搭起来的、为什么这么搭*。面向用户的文档见 [`../README.md`](../README.md)；
> 运行时技能规格见 [`../SKILL.md`](../SKILL.md)；开发本仓库的指南见 [`../AGENTS.md`](../AGENTS.md)。

## 1. 它解决什么问题

编码 Agent（Claude Code / Codex / opencode）和它要改的代码库，经常**不在同一台机器上**。
remote-harness 把两者连起来：让 Agent 像改本地文件一样改代码，而构建/测试在真正存放代码的那台机器上跑。
它**两个方向都支持**，并给用户**一条可复制执行的命令**来完成挂载 + 启动。

核心约束：

- **运行时零依赖**，除了 `ssh` + `sshfs`（其余全是 POSIX shell）。
- **不留持久痕迹**：挂载、隧道、注入的规则都在退出时拆掉；不写任何全局文件，被挂载的仓库也绝不被修改。
- **由 Agent 驱动，但绝不擅自决定**：Agent 跑的是一个连续流程，但每个有后果的选择都必须*向用户确认*。

## 2. 核心模型 —— 两个方向，一个不变式

两个通用角色：

- **A** = 运行 **Agent** 的机器。
- **P** = 存放**项目/代码**的机器，用一个 ssh `<别名>` 指代。

```
                 反向 reverse                              正向 forward
   A = 远程盒子              P = 笔记本           A = 本机              P = 远程服务器
   （Agent 在这）        （代码在这，NAT 后）     （Agent 在这）        （代码在这）
        │  反向 SSH 隧道       ▲                       │  直连 ssh          ▲
        ▼ （笔记本主动外连）   │                       ▼                    │
   sshfs 挂载  ◀── 笔记本项目                     sshfs 挂载 ◀── 服务器项目
```

- **反向（reverse）** —— A 是远程盒子，P 是 NAT 后面的用户笔记本。盒子无法主动连笔记本，所以由笔记本开一条
  **反向 SSH 隧道**（`RemoteForward <端口> 127.0.0.1:22`），盒子再通过这条隧道把笔记本项目 sshfs 挂回来。
  由跑在笔记本上的 `laptop-setup.sh` 编排。
- **正向（forward）** —— A 是本机，P 是可直接 ssh 到的服务器。无需隧道；本机直接把服务器项目 sshfs 挂到本地。
  由本地的 `local-setup.sh` 编排。

两个方向共享**同一个不变式**：

> 把 P 的项目 sshfs 挂到 A 上的一个**空目录** → 注入一条规则，让构建/测试**在 P 上**跑
> （`ssh <别名> 'cd <路径> && …'`）→ 在挂载点启动 Agent。

"空目录"是结构性要求：sshfs 会遮蔽挂载点里已有的内容，而远端项目必须干净地成为项目根。

## 3. 分层架构

remote-harness 刻意分成四层，从"Agent 读什么"一路向下到"实际跑什么"。这是让 Agent 提示词保持精简、
让行为保持确定性的关键设计决策。

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1. 技能规格   SKILL.md（+ reference/{reverse,forward,scripts}.md）      │  ← Agent 读这一层
│    渐进式披露：精简入口 → 按需读取对应方向的流程                          │
├──────────────────────────────────────────────────────────────────────┤
│ 2. 编排脚本   laptop-setup.sh（反向）· local-setup.sh（正向）           │  ← 那条被输出的命令
│    自包含、交互式，在用户那一侧运行                                       │
├──────────────────────────────────────────────────────────────────────┤
│ 3. 辅助脚本   detect/preflight/setup-tunnel/check-tunnel/mount-…        │  ← 确定性的单元
│    一个脚本一个职责，stdout 输出 KEY=VALUE，stderr 输出人工提示          │
├──────────────────────────────────────────────────────────────────────┤
│ 4. 共享库     _common.sh（被 source，从不执行）                          │  ← 颜色/引用/ssh 配置
└──────────────────────────────────────────────────────────────────────┘
   各 Agent 入口（claude/codex/opencode）+ manage.sh 安装都指向第 1 层。
```

### 第 1 层 —— 技能规格（渐进式披露）

`SKILL.md` 是精简入口：技能做什么、交互规则、选方向。每个方向的细节放在 `reference/` 下，运行时**按需**读取：

- `reference/reverse.md` —— 完整的反向流程（识别用户 → 建隧道 → 输出笔记本命令）。
- `reference/forward.md` —— 完整的正向流程（选服务器/目录 → 输出本地命令）。
- `reference/scripts.md` —— 各辅助脚本的 `KEY=VALUE` 契约。

每份文档都配一份中文 `*.cn.md`（中文是主要受众）；`README.md` 是内联双语、`CLAUDE.md` 是软链，所以这两份豁免。

### 第 2 层 —— 编排脚本

Agent 自己从不挂载任何东西。它拼出**一条命令**，由用户在持有代码侧凭据的那台机器上粘贴执行，
这条命令会跑一个自包含的编排脚本：

- **`laptop-setup.sh`**（反向，在笔记本上跑）—— 下文的 Phase 1-5。它必须能**独立运行**：笔记本通常没有安装，
  所以被输出的命令会把 `laptop-setup.sh` *和* `_common.sh` 一起 fetch 到同一个临时目录
  （`laptop-setup.sh` 从同级目录 source `_common.sh`）。这个"独立性"是硬性不变量——它需要的任何东西都不能只存在于安装目录里。
- **`local-setup.sh`**（正向，本地跑）—— 解析出到服务器的稳定 ssh 别名，挂载，注入规则，在本地启动 Agent，退出时卸载。

### 第 3 层 —— 辅助脚本（KEY=VALUE 契约）

每个脚本**只负责一件事**，并遵守严格的 I/O 契约：**stdout 输出 `KEY=VALUE` 行**（Agent 可机器解析），
**stderr 输出人工提示**。这让 Agent 能可靠解析结果，而不必脆弱地去抓自然语言。

| 脚本 | 方向 | 职责 | 主要输出 |
|---|---|---|---|
| `detect.sh` | 反向 | 只读环境探测 | `REALUSER_GUESS/SOURCE/CANDIDATES`、`SUGGESTED_PORT`、`DEFAULT_IDENTITY`、`SSHD_TCP_FORWARDING`、`ON_REMOTE` |
| `preflight.sh` | 两向 | 一次性门禁（取代多次往返） | `PREFLIGHT=ok\|blocked`、`BLOCKED_STEP`/`ERROR`/`REMEDY`、`TUNNEL_ALIAS/PORT`、`PROJECT_DIR_EMPTY` |
| `setup-tunnel.sh` | 反向 | 写盒子端 `<RU>-mac` 别名 + 推导端口 | `ALIAS`、`PORT`、`PUBKEY`、`REMOTEFORWARD_LINE` |
| `connect-guesses.sh` | 反向 | 猜测笔记本如何连到盒子 | `ssh user@ip` 行 |
| `server-guesses.sh` | 正向 | 猜测出站 ssh 目标（服务器） | `ssh <target>` 行 |
| `check-tunnel.sh` | 反向 | 验证监听器 + 通过隧道真实登录 | `SSH=up\|down`、`LAPTOP_HOSTNAME/USER` |
| `mount-project.sh` | 两向 | sshfs 挂载/卸载到本地路径 | `STATUS=mounted\|already-mounted\|need-sshfs\|not-empty\|failed\|unmounted` |
| `list-projects.sh` | 两向 | 枚举候选项目目录（本地或 `--via`） | `PROJECT\t<路径>\tgit:<分支>` |
| `inject-rule.sh` | 两向 | 会话级"在 P 上构建"规则 + 各 Agent 启动参数 | `RH_STATUS`、`RH_LAUNCH_ENV`、`RH_LAUNCH_FLAGS` |

### 第 4 层 —— 共享库

`_common.sh` 被 **source，从不执行**。它提供颜色 + 输出辅助（`say/ok/warn/err/hdr`）、交互式 `ask`
（尊重 `ASSUME_YES`）、OS 检测（`OS/PLAT/IS_WSL`），以及对安全最关键的两块：

- **`sq()`** —— 把一个值 shell 引用后安全拼进远端命令字符串。每个要拼进 ssh 命令的值都过一遍 `sq()`；
  路径里合法地可能含单引号（macOS），不加引号的拼接是注入/出错风险。
- **`parse_via()` + `write_managed_alias()`** —— 把原始 ssh 连接串（`-J jump -p 2222 user@host -i key`）
  解析成字段，并把一个幂等的托管 `Host` 块写进 `~/.ssh/config`。连接串是刻意做词拆分、**从不 `eval`**，
  所以一个精心构造/拼错的串不会在本地执行。复杂的 ssh 语义（`ProxyCommand`、`-F`、空格）会被拒绝，
  并提示"把它写进 `~/.ssh/config` 的 Host 别名"。

## 4. 反向流程细节

`laptop-setup.sh` 在笔记本上自动化五个阶段：

1. **Phase 1 —— SSH 服务 + 密钥 + 配置。** 确保 sshd 在跑，把盒子公钥加进 `~/.ssh/authorized_keys`，
   并写一个**专用**托管别名 `<host>-remote-harness`，其中带 `RemoteForward <端口> 127.0.0.1:22` + 保活 +
   `ExitOnForwardFailure yes`。之所以*专用*（不用用户的普通别名），是为了让普通的 `ssh <host>` 永远不会
   继承 RemoteForward 而在某个端口已被隧道占用时失败。
2. **Phase 2 —— 重连 → 隧道建立。** 开 `ssh -N <host>-remote-harness`，轮询直到盒子的回环端口在监听。
   信任一个已存在的监听器之前，它会**校验归属**（通过 `check-tunnel.sh` 比对 hostname + user）：若该端口被
   另一个/陈旧的隧道占用，它会扫描后续 200 个端口，改写笔记本侧 RemoteForward *和*盒子端别名，并用第一个空闲端口继续。
3. **Phase 3 —— 选笔记本项目目录**（readline 提示；`--project-dir` 给出已确认的默认值，路径无效时再次提示）。
4. **Phase 4 —— 在盒子上挂载**：ssh 到盒子，通过隧道运行 `mount-project.sh`（sshfs 缺失/非空时交互式重试）。
5. **Phase 5 —— 注入规则 + 启动**：先 `inject-rule.sh on …`，再 `ssh -t` 进入一个登录+交互 shell，
   使 PATH（例如 `~/.local/bin`）能解析出 Agent CLI。

一个 trap 装上**自动清理**：退出时卸载盒子挂载点、移除会话规则、断开隧道。

### 两个不同的 ssh 别名（一个微妙但重要的点）

| 别名 | 位于 | 方向 | 由谁写 | 携带 |
|---|---|---|---|---|
| `<RU>-mac` | **盒子**的 `~/.ssh/config` | 盒子 → 笔记本 | `setup-tunnel.sh` | `HostName 127.0.0.1`、`Port <rport>`、笔记本登录用户/密钥 |
| `<host>-remote-harness` | **笔记本**的 `~/.ssh/config` | 笔记本 → 盒子 | `laptop-setup.sh` | 真实连接参数**外加** `RemoteForward <rport> 127.0.0.1:22` |

盒子用 `ssh <RU>-mac` 连回笔记本（注入的规则用的就是它）；笔记本用 `ssh <host>-remote-harness`
连到盒子——并*建立*隧道。

## 5. 正向流程细节

`local-setup.sh` 在本地跑，更简单（无隧道）：

1. 从 `--via` 解析服务器连接。原始连接串（显式 user/port/key/跳板）会被持久化成一个托管 `<host>-dev` 别名；
   裸别名/主机则按原样使用。
2. 把 `<alias>:<remote-path>` sshfs 挂到本地空目录（默认 `~/remote-harness-mounts/<name>`），交互式重试同反向。
3. 注入"在服务器上构建"的规则（`inject-rule.sh`），然后在挂载点里**本地**启动 Agent（子 shell + `exec`，
   使清理 trap 仍会触发；限定到 bash/zsh，因为环境前缀 `VAR=val` 形式 fish/csh 不支持）。
4. 退出时卸载。

正向基本免疫反向要解决的共享账号冲突（见 §7），因为每个用户都在自己机器上跑 Agent、写自己的 `~/.ssh/config`。

## 6. 会话级规则注入（按 Agent 区分）

Agent 工作在一个 sshfs 挂载里，但宿主机可能没有项目的工具链。在那上面跑 `npm install` / `cargo build` /
linter / 语言服务器，会把错误 OS/架构的产物污染进挂载、悄悄损坏代码宿主机。所以 `inject-rule.sh` 注入一条规则
——"每一次构建/测试/lint/安装，以及 `git commit`/`push`，都在 `<别名>` 上跑，绝不在本机"——
并带上从项目清单文件嗅探出来的**按技术栈定制的示例命令**。

关键在于这条规则是**会话级**的：产物落在 `$RH_HOME/.sessions/<key>` 下（key 由挂载点派生），不写任何全局文件，
也绝不碰被挂载的仓库。每个 Agent 用它支持的最干净的作用域通道：

- **claude** → `--append-system-prompt-file <rule>`（仅本会话的标志）。
- **opencode** → `OPENCODE_CONFIG=<会话配置>`（环境变量；`instructions` + yolo 下的 `permission:"allow"`），
  叠加合并在用户配置之上。
- **codex** → `-c developer_instructions=<rule>`（仅本会话的 CLI 配置，保持真实 `CODEX_HOME` 不变，
  使 keyring 支撑的鉴权仍能工作）。非 yolo 还会加 `-s workspace-write` + `network_access=true` +
  `writable_roots=["~/.ssh"]`，让 codex 的沙箱允许规则里的出站 ssh 以及 ssh 自身对 `~/.ssh` 的写入。

`off` 在退出时直接删掉会话目录。

## 7. 共享盒子账号上的多用户命名空间（反向）

当一个盒子账号被多个真实用户共享时，所有盒子端状态都落在同一个 `$HOME` 下，他们的反向隧道会冲突——
而且盒子端别名可能被串线，导致一个用户的构建/提交跑到了另一个用户的笔记本上。修法（完整分析见
[`../issues/issue1.md`](../issues/issue1.md)）是引入一个经确认的**按真实用户命名空间 `RU`**：

- `detect.sh` 按优先级从以下来源猜 `RU`：本次会话登录所用公钥的**完整** comment（从 sshd 在
  `ExposeAuthInfo yes` 下写入的 `$SSH_USER_AUTH` 文件读取；其本地部分作为更友好的候选）、`~/<名字>/…`
  启动目录第一层、或 authorized_keys 里的 comment——然后由 Agent **确认**它（第四个"确认，不推断"的值）。
- 盒子端别名变成 `<RU>-mac`，反向端口由 `RU` **稳定哈希**到临时端口下界以下 `[20022, 29922]` 的一个 `.22`
  槽位（使不同用户落在不同端口，同一用户重连落在同一端口——从而支持**一条隧道 / 多个项目**复用）。
  `setup-tunnel.sh` 从 `--namespace` 推导；`preflight.sh --alias <RU>-mac` *只*复用该用户的隧道。
- 对共享 `~/.ssh/config` 的写入用 `flock` 串行化，使并发 setup 不互相覆盖托管块。

规则是：**端口 + 别名按真实用户（稳定）；挂载点 + 会话按项目。**

## 8. 横切不变量

以下贯穿整个代码库，并在评审/测试中强制执行：

1. **确认，不推断。** 方向、代码位置、挂载点，以及（反向、共享账号时）命名空间 `RU`，每一个都是用户显式选择
   ——检测只负责*预填*。
2. **`laptop-setup.sh` 保持独立**（被 fetch 到没有安装的笔记本；从同级 source `_common.sh`）。
3. **`inject-rule.sh` 方向中立，且从不写被挂载的仓库。**
4. **每个拼进远端命令的值都用 `sq()` 做 shell 引用**；绝不 `eval` `--via`。
5. **可移植性** —— 目标 Linux、WSL、macOS。`#!/usr/bin/env bash`；避免 GNU 专有标志；监听检查走
   `ss → netstat -an → lsof`；macOS 用 **FUSE-T**（无内核扩展），绝不用 macFUSE；必须持续输出的探针用
   `set -uo pipefail`（不用 `-e`）。
6. **stdout 输出 `KEY=VALUE`，stderr 输出人工提示** —— 解析契约。
7. **双语文档** —— 每份 `*.md` 都配 `*.cn.md`（`README.md`、`CLAUDE.md` 除外）。

## 9. 生命周期、幂等性与清理

- **幂等** —— 重跑 remote-harness 会复用活着的隧道和正确的现有挂载；托管 ssh 块是"建或替换"；改 ssh 配置前先备份。
- **陈旧挂载检测** —— `mount-project.sh` 检查挂载是否真的*活着*（不是隧道断开后留下的死 sshfs 端点），否则重挂。
- **自动拆除** —— 两个编排脚本都装了退出 trap，会卸载并移除会话规则。反向模式下隧道做**引用计数**：
  仅当盒子上不再有其它会话的挂载依赖它时才断开，最后一个退出的会话通过 pid 文件把它拆掉——因此同一用户的
  多项目会话可以任意顺序退出，互不弄断对方的挂载。`manage.sh --uninstall` 从不碰你的 ssh 隧道配置或挂载。

## 10. 安装与分发

`manage.sh` 把共享核心安装到 `~/.remote-harness/{SKILL.md, scripts/, reference/}`，外加各 Agent 的入口：
Claude Code 和 Codex 都拿原生 skill（`SKILL.md`），opencode 拿一个自定义命令。`--dev` 软链到仓库（改动即时生效）；
`--uninstall` 移除入口。在任何 `rm` 之前，它都对 `RH_HOME` 做硬性守卫（必须绝对路径、以 `remote-harness` 结尾、
绝不是 `/` 或 `$HOME`）。

## 11. 测试

- `bash -n scripts/*.sh manage.sh tests/regression.sh` —— 语法门禁，每次改动后跑。
- `tests/regression.sh` —— 一个 hermetic 套件，覆盖 `parse_via`/托管别名写入、项目扫描 + 引用、各 Agent 规则注入、
  反向端口冲突兜底、隧道复用路径、`RU`/命名空间推导 + 稳定端口同步、launch 校验、`manage.sh` 的 `RH_HOME` 守卫，
  以及**双语文档配对**检查（每份 `*.md` 都有 `.cn.md`）。
- `tests/codex_tui_e2e.py` —— 一个 live（非 hermetic）的 pexpect 冒烟测试，驱动 Codex TUI 走完技能，
  验证结构化 `request_user_input` 提示。

## 12. 文件地图

```
remote-harness/
├── SKILL.md / SKILL.cn.md       # 第 1 层：精简技能入口
├── reference/                   # 第 1 层：渐进式披露的细节
│   ├── reverse.md  forward.md   # 各方向流程
│   └── scripts.md               # KEY=VALUE 契约（各配 .cn.md）
├── scripts/                     # 第 2-4 层
│   ├── _common.sh               # 第 4 层：被 source 的库
│   ├── preflight.sh detect.sh setup-tunnel.sh check-tunnel.sh connect-guesses.sh   # 反向探针
│   ├── server-guesses.sh        # 正向探针
│   ├── laptop-setup.sh          # 第 2 层：反向编排（独立）
│   ├── local-setup.sh           # 第 2 层：正向编排
│   └── mount-project.sh inject-rule.sh list-projects.sh   # 两向复用
├── adapters/{codex,opencode}.md # Agent 入口说明（设置 --launch）
├── manage.sh                    # 安装 / --dev / --uninstall
├── docs/design.md               # 本文档（+ .cn.md）
├── issues/issue1.md             # 共享账号命名空间分析（+ .cn.md）
├── tests/regression.sh codex_tui_e2e.py
├── AGENTS.md（+ CLAUDE.md 软链）   # 给开发本仓库的 Agent 的指南
└── README.md                    # 面向用户，内联双语
```
