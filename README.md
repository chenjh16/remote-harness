<h1 align="center">remote-harness</h1>

<p align="center">
  <b>把「运行 Agent 的机器」和「存放代码的机器」连起来——两个方向都行，一条命令搞定。</b><br>
  <i>Connect the machine your coding agent runs on with the machine your code lives on — either direction, one command.</i>
</p>

<p align="center">
  <img alt="platforms" src="https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20WSL-blue">
  <img alt="agents" src="https://img.shields.io/badge/agents-Claude%20Code%20%7C%20Codex%20%7C%20opencode-8A2BE2">
  <img alt="directions" src="https://img.shields.io/badge/directions-reverse%20%E2%87%84%20forward-success">
  <img alt="transport" src="https://img.shields.io/badge/transport-SSH%20%2B%20sshfs-orange">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-FUSE--T%20(no%20kext)-brightgreen">
  <img alt="shell" src="https://img.shields.io/badge/built%20with-Bash-1f425f">
  <img alt="deps" src="https://img.shields.io/badge/runtime%20deps-none%20(ssh%20%2B%20sshfs)-lightgrey">
</p>

<p align="center"><b>中文</b> · <a href="#english">English</a></p>

---

> **服务器 SSH/SSHFS 长连接提醒 / Server tuning note：** 如果一台远程开发服务器承载多用户、
> 多个长期 Agent 会话或大量 SSHFS 挂载，建议先优化 `sshd` 容量、keepalive、文件描述符和 TCP 队列。
> 参考 [`docs/ssh-sshfs-long-lived-connections.cn.md`](docs/ssh-sshfs-long-lived-connections.cn.md)
> / [`docs/ssh-sshfs-long-lived-connections.md`](docs/ssh-sshfs-long-lived-connections.md)。
> remote-harness 自身会使用会话级 SSH config、`sshfs reconnect` 和 keepalive，但服务器端容量仍会影响长期稳定性。

## 中文

### 目录

- [这是什么](#这是什么)
- [工作原理（两个方向）](#工作原理两个方向)
- [服务器 SSH/SSHFS 长连接优化提醒](#服务器-sshsshfs-长连接优化提醒)
- [安装](#安装)
- [使用](#使用)
- [环境要求](#环境要求)
- [仓库结构](#仓库结构)
- [安全与隐私](#安全与隐私)
- [故障排查](#故障排查)

### 这是什么

你的**编码 Agent**（Claude Code / Codex / opencode）和你的**代码库**经常不在同一台机器上。
`remote-harness` 把两者连起来：用 sshfs 把代码挂到 Agent 所在机器的一个空目录，注入一条规则让
**编译/测试在「代码所在的那台机器」上跑**，然后在挂载目录里启动 Agent。Claude Code/opencode 通过
`/remote-harness` 触发；Codex 用 `$remote-harness` 直接调用技能。默认 simple reverse 模式下，Agent
只给你一条命令；具体 SSH、路径、命名空间和挂载点都在你的本地终端里输入，不进入 Agent 聊天。

记号：**A** = 运行 Agent 的机器；**P** = 存放代码的机器（用一个 ssh `<别名>` 指代）。

### 工作原理（两个方向）

默认使用 simple reverse：Agent 在远端盒子，代码在你的笔记本。当你明确要求本地 Codex/Agent 开发服务器项目时，使用 simple forward。`reference/` 记录当前 simple 流程和脚本契约。

**① 反向（reverse）— Agent 在远程盒子，代码在你的笔记本（NAT 后）**

盒子无法主动连笔记本，所以笔记本开一条**反向 SSH 隧道**，再把笔记本项目挂到盒子上。

```
笔记本会话级 ssh_config：  Host <会话别名>   RemoteForward <端口> 127.0.0.1:22
        └─ 连接后，盒子的 sshd 在 127.0.0.1:<端口> 监听，转发回笔记本:22

盒子：  ssh <别名>          → 127.0.0.1:<端口> → （隧道） → 笔记本:22
        sshfs <别名>:/项目  → 同一条隧道       → 笔记本文件挂载到这里
```

反向和正向的 simple setup 都使用 `~/.remote-harness/.sessions/...` 下的会话级 SSH
配置和 `known_hosts`，并关闭 OpenSSH multiplexing。唯一的 `~/.ssh` 写入例外是反向模式可在笔记本
`~/.ssh/authorized_keys` 中追加带标签的临时授权块，并在退出时清理。

**② 正向（forward）— Agent 在本机，代码在可直连的远程服务器**

无需隧道：本机直接 ssh 到服务器，把服务器项目挂到本地空目录，Agent 在本地启动，构建经
`ssh <别名>` 在服务器上执行。

两个方向的不变式相同：**挂载到空目录 → 注入「在 `<别名>` 上构建」规则 → 在挂载点启动 Agent**。

### 服务器 SSH/SSHFS 长连接优化提醒

remote-harness 的单次会话会自动做这些事：使用会话级 SSH config；把临时 `known_hosts` 放在
`~/.remote-harness/.sessions/...`；关闭 OpenSSH multiplexing；给 `sshfs` 加 `reconnect` 和 keepalive；
并在退出时尽量清理挂载、规则和临时配置。

但如果远程服务器是多人共享开发盒子，服务器端仍需要足够的 SSH 容量。建议运维侧评估：

- `MaxStartups` / `MaxSessions`，避免突发 SSHFS 挂载时握手阶段被拒。
- `ClientAliveInterval` / `ClientAliveCountMax` / `TCPKeepAlive`，让长期连接更稳并回收半死会话。
- `ssh.service` 与 PAM 的 `nofile`，避免多用户 SFTP/SSHFS 先撞到文件描述符上限。
- `somaxconn`、`tcp_max_syn_backlog` 和 TCP keepalive sysctl，应对连接突发和长期 idle 连接。

完整配置模板、验证命令和回滚方法见
[`docs/ssh-sshfs-long-lived-connections.cn.md`](docs/ssh-sshfs-long-lived-connections.cn.md)。

### 安装

```bash
./manage.sh            # 复制安装到 ~/.remote-harness + 各 Agent 的入口
./manage.sh --dev      # 开发模式：软链到本仓库，改动即时生效
./manage.sh --uninstall [claude|codex|opencode]   # 卸载（不动你的 ssh 配置/挂载）
```

| Agent | 入口位置 | 调用 |
|---|---|---|
| 共享核心 | `~/.remote-harness/{SKILL.md, SKILL.cn.md, scripts/, reference/, docs/}` | （各方共用） |
| Claude Code | `~/.claude/skills/remote-harness/SKILL.md` | `/remote-harness` |
| Codex | `~/.codex/skills/remote-harness/SKILL.md` | `$remote-harness` |
| opencode | `~/.config/opencode/command/remote-harness.md` | `/remote-harness` |

**脚本**是唯一的单一事实来源——各 Agent 都调用 `~/.remote-harness/scripts/*`。每个 Agent 的入口
形态不同：Claude Code 与 Codex 都是原生 *skill*（共用同一份 `SKILL.md`；Codex 无自定义斜杠命令，推荐用
`$remote-harness` 直接调用技能），opencode 是让 Agent 去读共享 `SKILL.md` 的自定义命令。

### 使用

在你的 Agent 里启动 remote-harness：Claude Code/opencode 运行 `/remote-harness`（加 yolo：
`/remote-harness 开启yolo模式`）；Codex 输入 `$remote-harness`（加 yolo：`$remote-harness yolo模式，中文`）。
默认 simple reverse 会：

1. 让 Agent 直接返回一条本地 bootstrap 命令。公开入口统一是 `simple-bootstrap.sh`；
   如果脚本在远端 skill 目录，命令会先从远端读取它再在本地运行。
2. 你在笔记本终端运行该命令，并输入远端 SSH target、本地项目目录、可选远端挂载点。
3. bootstrap 建立反向隧道，把笔记本项目挂到远端。
4. 在远端挂载目录启动所选 Agent，并注入“构建/测试在笔记本上跑”的会话规则。
5. 退出 Agent 时**自动卸载**。随时再次启动 remote-harness 重新连接（幂等；陈旧挂载会被检测并重挂）。

如果你要让 **Codex 在本地运行、项目和开发环境在服务器上**，直接说明这个需求，例如
`$remote-harness 中文，本地 Codex 开发服务器上的项目`。simple forward 走同一个 bootstrap 入口并传入
`--mode forward`；它把服务器项目映射到本地目录，本地负责文件读写/编辑/搜索，构建、运行、测试等项目命令通过 SSH 在服务器执行。
简短说“本地开发远程项目”即可触发 forward；简短说“远程开发本地”即可触发 reverse。若说法无法判断，
命令会在本地先让你选择模式，第一次默认 reverse，并记住上次选择。

### 环境要求

- 你已经能从一台机器 ssh 到另一台（任意端口 / 常见 `-J` 跳板机都行）。复杂 SSH 选项
  （`ProxyCommand`、`-F`、带空格的引号路径、本地转发等）请先写进 `~/.ssh/config` 的 `Host` 别名，再把别名交给 remote-harness。
- **反向 simple**：你已经把笔记本的 SSH 公钥配置到远端服务器账号，所以本地命令能先登录远端抓取脚本。
  远端会在自己的 `~/.remote-harness/keys` 下生成/复用 remote-harness key；本地脚本可将其公钥作为
  `remote-harness:reverse-auth:<tag>` 临时块写入笔记本 `~/.ssh/authorized_keys`，限制为回环来源并在退出时清理。
  盒子的 sshd 需要允许 TCP 转发（默认即可）。
- **挂载发生的那台机器需要 `sshfs` + FUSE**——反向是盒子、正向是本机：
  - Linux/WSL：`sudo apt-get install -y sshfs`（FUSE 通常已就绪；脚本会按发行版给正确命令）。
  - **macOS：用 FUSE-T——无内核扩展、无需降低系统安全级**：
    `brew install macos-fuse-t/homebrew-cask/fuse-t && brew install macos-fuse-t/homebrew-cask/sshfs-fuse-t`。
    **不要用 macFUSE**（它要求降低安全策略）。FUSE-T 保留 sshfs 的同步写，编辑会先落到代码所在机器
    再触发远端构建。（无内核扩展的兜底：`rclone nfsmount`——但写是异步的，故本场景优先 FUSE-T。）
- 多用户共享远程开发服务器建议按
  [`docs/ssh-sshfs-long-lived-connections.cn.md`](docs/ssh-sshfs-long-lived-connections.cn.md)
  调整 sshd 容量、keepalive、`nofile` 和 TCP 队列。该优化不是 remote-harness 的硬性前置条件，
  但会显著提升大量长期 SSH/SSHFS 会话的稳定性。

### 仓库结构

```
remote-harness/
├── SKILL.md                  # simple reverse / simple forward 入口：只输出本地 bootstrap 命令
├── reference/
│   ├── reverse.md            # 反向完整流程（建隧道 → 发命令）
│   ├── forward.md            # 正向完整流程（选服务器 / 目录 → 发命令）
│   └── scripts.md            # 各脚本的 KEY=VALUE 契约
├── scripts/                  # 确定性逻辑（KEY=VALUE 输出），Agent 无关
│   ├── _common.sh            # 共享库（颜色/ask/sq/parse_via/写托管别名/OS 变量）
│   ├── simple-bootstrap.sh   # simple 统一入口（本地运行；可从远端读取）
│   ├── simple-dispatch.sh    # 本地选择/分发 reverse/forward
│   ├── simple-laptop-setup.sh simple-local-setup.sh  # 分模式本地向导
│   ├── suggest-via.sh        # simple 反向：远端 SSH target 默认值
│   ├── setup-tunnel.sh check-tunnel.sh   # 反向隧道的会话级别名 / 检查
│   ├── mount-project.sh inject-rule.sh   # 两向复用的挂载与规则注入
│   ├── laptop-setup.sh       # 反向编排（在笔记本上跑）
│   └── local-setup.sh        # 正向编排（在本机上跑）
├── adapters/{codex,opencode}.md   # 各 Agent 的入口（只设置 --launch）
├── manage.sh                 # 安装 / --dev / --uninstall
├── docs/                     # 设计与完整流程文档（安装时一并复制/软链）
│   └── ssh-sshfs-long-lived-connections*.md  # 共享服务器 SSH/SSHFS 长连接优化
├── issues/issue1.md          # 共享账号命名空间隔离分析（+ .cn.md）
├── AGENTS.md（+ CLAUDE.md 软链）   # 给「开发本仓库」的 Agent 的指南
└── README.md
```

> **设计文档**：想了解整体架构、四层结构与设计决策，见 [`docs/design.md`](docs/design.md)（中文版
> [`docs/design.cn.md`](docs/design.cn.md)）。
>
> **文档约定**：除 `README.md`（本文，内联双语）外，所有 `*.md` 都配一份中文 `*.cn.md`。详见 `AGENTS.md`。

### 安全与隐私

- simple setup 不在本地或远端 `~/.ssh/config`、`known_hosts`、SSH key、`config.rh-bak.*` 或
  `known_hosts_<alias>` 下创建、修改、备份、追加或清理内容。所有临时 SSH alias 和 `known_hosts`
  都位于 `~/.remote-harness/.sessions/...`，并在会话结束时尽量清理；会话 config 关闭 OpenSSH multiplexing。
- 反向模式的唯一 `~/.ssh` 写入例外是本机 `authorized_keys`：脚本会先检查是否已有匹配有效 key；
  没有时才追加带 `remote-harness:reverse-auth:<tag>` 标签、`from="127.0.0.1,::1"` 限制的临时块。
  托管块通过 `~/.remote-harness/.sessions/authorized-keys/...` 引用计数，最后一个会话退出时删除。
- 反向隧道用 `RemoteForward <端口> 127.0.0.1:22`（仅回环）；多用户盒子上同机其他用户能到达该端口，
  但没有你的私钥无法认证。
- 多人共用同一个服务器账号时，simple reverse 默认使用会话别名 `rlocal`，别名和 known_hosts 都放在
  远端会话目录中；不会覆盖共享账号的 `~/.ssh/config`。同一台笔记本的多项目会话仍可复用活动隧道，
  最后一个会话退出时清理。
- `--yolo` 会绕过审批，**仅在你明确要求时**才启用；opencode 的 `permission:allow` 只写进**本次会话**
  的配置，退出即清。
- 注入的规则是**会话级**的（不写全局文件、不碰挂载的仓库）；退出删除会话目录。

### 故障排查

详见 `reference/reverse.md` / `reference/forward.md` 末尾。常见：
- macOS 提示要 macFUSE → 改用 FUSE-T（见[环境要求](#环境要求)）。
- 会话中文件突然读不了（`Transport endpoint is not connected`）→ 隧道断了，退出 Agent 后再次启动
  remote-harness，会自动检测陈旧挂载并重挂。
- 挂载报 `not-empty` → 换一个空目录（脚本会提示）。

---

## English

### Table of Contents

- [What it is](#what-it-is)
- [How it works (two directions)](#how-it-works-two-directions)
- [Server SSH/SSHFS Long-Lived Connection Tuning](#server-sshsshfs-long-lived-connection-tuning)
- [Install](#install)
- [Usage](#usage)
- [Requirements](#requirements)
- [Repo layout](#repo-layout)
- [Security & privacy](#security--privacy)
- [Troubleshooting](#troubleshooting)

### What it is

Your **coding agent** (Claude Code / Codex / opencode) and your **codebase** often live on different
machines. `remote-harness` connects them: it sshfs-mounts the code onto an empty dir where the agent
runs, injects a rule so **builds/tests run on the machine that hosts the code**, and launches the
agent in the mount. Claude Code/opencode trigger it with `/remote-harness`; Codex users invoke the
skill with `$remote-harness`. In the default simple reverse mode, the agent returns one command;
concrete SSH targets, paths, namespaces, and mountpoints are entered in the user's local terminal,
not in chat. Generically: **A** = the machine the agent runs on; **P** = the
machine the code lives on (an ssh `<alias>`).

### How it works (two directions)

The default is simple reverse: agent on a remote box, code on your laptop. When you explicitly ask
for local Codex/agent with a server project, use simple forward. `reference/` documents the current
simple flows and script contracts.

**① Reverse — agent on a remote box, code on your laptop (behind NAT).** The box can't dial the
laptop, so the laptop opens a **reverse SSH tunnel** and its project is sshfs-mounted onto the box.

```
laptop session ssh_config:  Host <session-alias>   RemoteForward <PORT> 127.0.0.1:22
        └─ on connect, the box's sshd listens on 127.0.0.1:<PORT> and forwards back to laptop:22
box:   ssh <alias>          → 127.0.0.1:<PORT> → (tunnel) → laptop:22
       sshfs <alias>:/proj  → same tunnel       → laptop files mounted here
```

Both simple directions use session-local SSH config files and `known_hosts` under
`~/.remote-harness/.sessions/...`, with OpenSSH multiplexing disabled. The only `~/.ssh` write exception is reverse mode: the
laptop may get a tagged temporary `authorized_keys` block that is removed on exit.

**② Forward — agent local, code on a directly ssh-reachable server.** No tunnel: the local machine
ssh's straight to the server, mounts its project onto a local empty dir, the agent runs locally, and
builds run on the server via `ssh <alias>`.

Both share the invariant: **mount onto an empty dir → inject "build on `<alias>`" → launch the agent
in the mount.**

### Server SSH/SSHFS Long-Lived Connection Tuning

Each remote-harness session already uses session-local SSH config, keeps temporary `known_hosts`
under `~/.remote-harness/.sessions/...`, disables OpenSSH multiplexing, passes `reconnect` and
keepalive options to `sshfs`, and cleans up mounts/rules/temp configs on exit where possible.

For shared remote development servers, server-side capacity still matters. Operators should review:

- `MaxStartups` / `MaxSessions`, so bursty SSHFS mounts are not rejected during authentication.
- `ClientAliveInterval` / `ClientAliveCountMax` / `TCPKeepAlive`, so long sessions survive short
  network blips and dead sessions are reclaimed.
- `ssh.service` and PAM `nofile`, so SFTP/SSHFS workloads do not hit low file descriptor limits.
- `somaxconn`, `tcp_max_syn_backlog`, and TCP keepalive sysctls for connection bursts and idle flows.

See the full template, verification commands, and rollback notes in
[`docs/ssh-sshfs-long-lived-connections.md`](docs/ssh-sshfs-long-lived-connections.md).

### Install

```bash
./manage.sh            # copy-install to ~/.remote-harness + each agent's entry point
./manage.sh --dev      # dev mode: symlink to this repo (edits go live)
./manage.sh --uninstall [claude|codex|opencode]   # uninstall (leaves your ssh config/mounts alone)
```

| Agent | Location | Invoke |
|---|---|---|
| shared core | `~/.remote-harness/{SKILL.md, SKILL.cn.md, scripts/, reference/, docs/}` | (used by all) |
| Claude Code | `~/.claude/skills/remote-harness/SKILL.md` | `/remote-harness` |
| Codex | `~/.codex/skills/remote-harness/SKILL.md` | `$remote-harness` |
| opencode | `~/.config/opencode/command/remote-harness.md` | `/remote-harness` |

The **scripts** are the single source of truth — every agent calls `~/.remote-harness/scripts/*`.
Each agent's entry differs by what it supports: Claude Code and Codex both use a native *skill* (the
shared `SKILL.md`; Codex has no custom slash commands, so use `$remote-harness`); opencode is a
custom command that reads the shared `SKILL.md`.

### Usage

Start remote-harness in your agent: Claude Code/opencode run `/remote-harness` (add yolo:
`/remote-harness yolo`); Codex users type `$remote-harness` (add yolo:
`$remote-harness yolo模式，中文`). The default simple reverse flow will:

1. Have the agent return one local bootstrap command. The public entry is always
   `simple-bootstrap.sh`; if the script lives in a remote skill directory, the command fetches it
   from there and then runs it locally.
2. You run it on the laptop and enter the remote SSH target, local project dir, and optional remote
   mountpoint.
3. The bootstrap opens the reverse tunnel and mounts the laptop project on the remote box.
4. It launches the chosen agent in the remote mount and injects the session-scoped run-on-laptop rule.
5. **Auto-unmounts on exit.** Start remote-harness again anytime to reconnect (idempotent; a stale
   mount is detected and replaced).

For **local Codex with the project and dev environment on a server**, say that explicitly, e.g.
`$remote-harness local Codex, project on server`. Simple forward uses the same bootstrap entry with
`--mode forward`: it mounts the server project locally, uses local file reads/writes/edits/searches, and runs
build/run/test project commands on the server through SSH.
Short phrases like "本地开发远程项目" trigger forward; "远程开发本地" triggers reverse. If the wording
is ambiguous, the command asks for the mode locally, defaults to reverse on first run, and remembers
the last choice.

### Requirements

- You can already ssh from one machine to the other (any port / common `-J` jump host is fine).
  For complex SSH options (`ProxyCommand`, `-F`, quoted paths with spaces, local forwards, etc.),
  put them in `~/.ssh/config` as a `Host` alias and give remote-harness that alias.
- **Simple reverse**: the laptop's SSH public key is already accepted by the remote server account,
  so the local command can fetch scripts from the remote box. The box generates/reuses a
  remote-harness key under its own `~/.remote-harness/keys`; the local setup may add that public key
  to the laptop's `~/.ssh/authorized_keys` as a tagged, loopback-scoped temporary block and remove it
  on exit. The box's sshd must allow TCP forwarding (the default).
- **The machine that does the MOUNT needs `sshfs` + FUSE** — the box (reverse) or your local machine
  (forward):
  - Linux/WSL: `sudo apt-get install -y sshfs` (FUSE usually present; the script gives the right
    per-distro command).
  - **macOS: use FUSE-T — no kernel extension, no reduced system security**:
    `brew install macos-fuse-t/homebrew-cask/fuse-t && brew install macos-fuse-t/homebrew-cask/sshfs-fuse-t`.
    Avoid macFUSE (it requires lowering security). FUSE-T keeps sshfs's synchronous writes, so edits
    land on the host before remote builds. (Kext-less fallback: `rclone nfsmount`, but its writes are
    async — prefer FUSE-T for this edit-here/build-on-host workflow.)
- Shared remote development servers should use
  [`docs/ssh-sshfs-long-lived-connections.md`](docs/ssh-sshfs-long-lived-connections.md) to tune sshd
  capacity, keepalive, `nofile`, and TCP queues. This is not a hard prerequisite for remote-harness,
  but it materially improves stability with many long-lived SSH/SSHFS sessions.

### Repo layout

```
remote-harness/
├── SKILL.md                  # simple reverse / simple forward entry: emits one local bootstrap command
├── reference/{reverse,forward,scripts}.md   # per-direction flows + script contracts
├── scripts/                  # deterministic helpers (KEY=VALUE stdout), agent-agnostic
│   ├── _common.sh            # shared lib (colors/ask/sq/parse_via/managed-alias/OS vars)
│   ├── simple-bootstrap.sh                   # unified simple entry (local run; remote-fetchable)
│   ├── simple-dispatch.sh                    # local reverse/forward selector + dispatcher
│   ├── simple-laptop-setup.sh simple-local-setup.sh  # mode-specific local wizards
│   ├── suggest-via.sh                        # simple reverse remote SSH target default
│   ├── setup-tunnel.sh check-tunnel.sh        # reverse session alias + tunnel check
│   ├── mount-project.sh inject-rule.sh        # shared mount + session rule helpers
│   ├── laptop-setup.sh                        # reverse orchestrator
│   └── local-setup.sh                         # forward orchestrator
├── adapters/{codex,opencode}.md
├── manage.sh
├── docs/                            # design and complete-flow docs (installed with the skill)
│   └── ssh-sshfs-long-lived-connections*.md  # shared-server SSH/SSHFS tuning
├── issues/issue1.md                 # shared-account namespacing analysis (+ .cn.md)
├── AGENTS.md (+ CLAUDE.md symlink)   # guide for agents developing this repo
└── README.md
```

> **Design doc:** for the overall architecture, the four-layer structure, and the design decisions,
> see [`docs/design.md`](docs/design.md) (Chinese: [`docs/design.cn.md`](docs/design.cn.md)).
>
> **Docs convention:** every `*.md` except `README.md` (this file, inline-bilingual) ships a Chinese
> `*.cn.md` counterpart. See `AGENTS.md`.

### Security & privacy

- Simple setup does not create, modify, back up, append to, or clean up local or remote
  `~/.ssh/config`, `known_hosts`, SSH keys, `config.rh-bak.*`, or `known_hosts_<alias>`. Temporary
  SSH aliases and `known_hosts` live under `~/.remote-harness/.sessions/...` and are cleaned up at
  session end where possible; session configs disable OpenSSH multiplexing.
- The only `~/.ssh` write exception is reverse-mode laptop `authorized_keys`: setup checks for an
  existing active matching key first, otherwise appends a tagged
  `remote-harness:reverse-auth:<tag>` block restricted with `from="127.0.0.1,::1"`. Managed blocks
  are reference-counted under `~/.remote-harness/.sessions/authorized-keys/...` and removed when the
  last session exits.
- The reverse tunnel binds loopback only (`RemoteForward <PORT> 127.0.0.1:22`); on a multi-user box
  other local users can reach that port but cannot authenticate without your private key.
- When several people share one server account, simple reverse uses the session alias `rlocal` and
  keeps alias/known_hosts state in the remote session directory, so one run does not overwrite the
  shared account's `~/.ssh/config`. Multiple projects from the same laptop can reuse a live tunnel;
  the last session out cleans it up.
- `--yolo` bypasses approvals and is applied **only when you ask**; opencode's `permission:allow`
  goes into the **per-session** config only and is gone on exit.
- The injected rule is **session-scoped** (no global files, never touches the mounted repo); the
  session dir is removed on exit.

### Troubleshooting

See the end of `reference/reverse.md` / `reference/forward.md`. Common ones:
- macOS asks for macFUSE → use FUSE-T instead (see [Requirements](#requirements)).
- Files become unreadable mid-session (`Transport endpoint is not connected`) → the tunnel dropped;
  exit the agent and start remote-harness again (it detects the stale mount and remounts).
- Mount reports `not-empty` → pick a different empty dir (the script prompts).
