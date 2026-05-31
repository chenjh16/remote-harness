<h1 align="center">remote-harness</h1>

<p align="center">
  <b>把「运行 Agent 的机器」和「存放代码的机器」连起来——两个方向都行,一条命令搞定。</b><br>
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

## 中文

### 目录

- [这是什么](#这是什么)
- [工作原理(两个方向)](#工作原理两个方向)
- [安装](#安装)
- [使用](#使用)
- [环境要求](#环境要求)
- [仓库结构](#仓库结构)
- [安全与隐私](#安全与隐私)
- [故障排查](#故障排查)

### 这是什么

你的**编码 Agent**(Claude Code / Codex / opencode)和你的**代码库**经常不在同一台机器上。
`remote-harness` 把两者连起来:用 sshfs 把代码挂到 Agent 所在机器的一个空目录,注入一条规则让
**编译/测试在「代码所在的那台机器」上跑**,然后在挂载目录里启动 Agent。Claude Code/opencode 通过
`/remote-harness` 触发;Codex 用 `$remote-harness` 直接调用技能。中间所有信息都**交互式向你确认**,最后给你**一条可复制执行的命令**。

记号:**A** = 运行 Agent 的机器;**P** = 存放代码的机器(用一个 ssh `<别名>` 指代)。

### 工作原理(两个方向)

启动后,它会**先问你方向**(不自动猜),然后逐项确认目录:

**① 反向(reverse)— Agent 在远程盒子,代码在你的笔记本(NAT 后)**

盒子无法主动连笔记本,所以笔记本开一条**反向 SSH 隧道**,再把笔记本项目挂到盒子上。

```
笔记本 ~/.ssh/config:  Host <别名>   RemoteForward <端口> 127.0.0.1:22
        └─ 连接后,盒子的 sshd 在 127.0.0.1:<端口> 监听,转发回笔记本:22

盒子:  ssh <别名>          → 127.0.0.1:<端口> → (隧道) → 笔记本:22
        sshfs <别名>:/项目  → 同一条隧道       → 笔记本文件挂载到这里
```

**② 正向(forward)— Agent 在本机,代码在可直连的远程服务器**

无需隧道:本机直接 ssh 到服务器,把服务器项目挂到本地空目录,Agent 在本地启动,构建经
`ssh <别名>` 在服务器上执行。

两个方向的不变式相同:**挂载到空目录 → 注入「在 `<别名>` 上构建」规则 → 在挂载点启动 Agent**。

### 安装

```bash
./manage.sh            # 复制安装到 ~/.remote-harness + 各 Agent 的入口
./manage.sh --dev      # 开发模式:软链到本仓库,改动即时生效
./manage.sh --uninstall [claude|codex|opencode]   # 卸载(不动你的 ssh 配置/挂载)
```

| Agent | 入口位置 | 调用 |
|---|---|---|
| 共享核心 | `~/.remote-harness/{SKILL.md, scripts/, reference/}` | (各方共用) |
| Claude Code | `~/.claude/skills/remote-harness/SKILL.md` | `/remote-harness` |
| Codex | `~/.codex/skills/remote-harness/SKILL.md` | `$remote-harness` |
| opencode | `~/.config/opencode/command/remote-harness.md` | `/remote-harness` |

**脚本**是唯一的单一事实来源——各 Agent 都调用 `~/.remote-harness/scripts/*`。每个 Agent 的入口
形态不同:Claude Code 与 Codex 都是原生 *skill*(共用同一份 `SKILL.md`;Codex 无自定义斜杠命令,推荐用
`$remote-harness` 直接调用技能),opencode 是让 Agent 去读共享 `SKILL.md` 的自定义命令。

### 使用

在你的 Agent 里启动 remote-harness:Claude Code/opencode 运行 `/remote-harness`(加 yolo:
`/remote-harness 开启yolo模式`);Codex 输入 `$remote-harness`(加 yolo:`$remote-harness yolo模式，中文`)。它会:

1. **问你方向**(reverse / forward;基于是否在 SSH 会话里预选默认项,但一定会问)。
2. **一次性预检**(环境 / sshfs+FUSE / 隧道或服务器可达性),卡在第一个缺失项并给出补救命令。
3. **逐项确认目录**:代码在哪个目录、挂载/启动在哪个空目录——都给候选+可自由输入。
4. 生成**一条可复制执行的命令**:挂载 + 启动 Agent(reverse 在笔记本上跑,forward 在本机上跑)。
5. 退出 Agent 时**自动卸载**。随时再次启动 remote-harness 重新连接(幂等;陈旧挂载会被检测并重挂)。

### 环境要求

- 你已经能从一台机器 ssh 到另一台(任意端口 / 常见 `-J` 跳板机都行)。复杂 SSH 选项
  (`ProxyCommand`、`-F`、带空格的引号路径、本地转发等)请先写进 `~/.ssh/config` 的 `Host` 别名，再把别名交给 remote-harness。
- **反向**:盒子的 sshd 允许 TCP 转发(默认即可);笔记本开启 SSH 服务,并已把盒子公钥加入
  `~/.ssh/authorized_keys`(脚本会打印要加的 key 和配置行)。
- **挂载发生的那台机器需要 `sshfs` + FUSE**——反向是盒子、正向是本机:
  - Linux/WSL:`sudo apt-get install -y sshfs`(FUSE 通常已就绪;脚本会按发行版给正确命令)。
  - **macOS:用 FUSE-T——无内核扩展、无需降低系统安全级**:
    `brew install macos-fuse-t/homebrew-cask/fuse-t && brew install macos-fuse-t/homebrew-cask/sshfs-fuse-t`。
    **不要用 macFUSE**(它要求降低安全策略)。FUSE-T 保留 sshfs 的同步写,编辑会先落到代码所在机器
    再触发远端构建。(无内核扩展的兜底:`rclone nfsmount`——但写是异步的,故本场景优先 FUSE-T。)

### 仓库结构

```
remote-harness/
├── SKILL.md                  # 精简入口(总览 + 交互规则 + 选方向);细节在 reference/
├── reference/
│   ├── reverse.md            # 反向完整流程(建隧道 → 发命令)
│   ├── forward.md            # 正向完整流程(选服务器/目录 → 发命令)
│   └── scripts.md            # 各脚本的 KEY=VALUE 契约
├── scripts/                  # 确定性逻辑(KEY=VALUE 输出),Agent 无关
│   ├── _common.sh            # 共享库(颜色/ask/sq/parse_via/写托管别名/OS 变量)
│   ├── preflight.sh          # 一次性预检 → ok / blocked(支持 --direction forward)
│   ├── detect.sh setup-tunnel.sh connect-guesses.sh check-tunnel.sh   # 反向:建隧道
│   ├── server-guesses.sh     # 正向:推断出站服务器目标
│   ├── laptop-setup.sh       # 反向编排(在笔记本上跑)
│   ├── local-setup.sh        # 正向编排(在本机上跑)
│   ├── mount-project.sh inject-rule.sh list-projects.sh   # 两向复用
├── adapters/{codex,opencode}.md   # 各 Agent 的入口(只设置 --launch)
├── manage.sh                 # 安装 / --dev / --uninstall
├── AGENTS.md (+ CLAUDE.md 软链)    # 给「开发本仓库」的 Agent 的指南
└── README.md
```

> **文档约定**:除 `README.md`(本文,内联双语)外,所有 `*.md` 都配一份中文 `*.cn.md`。详见 `AGENTS.md`。

### 安全与隐私

- ssh 配置改动前会备份;反向隧道别名用独立的 per-alias `known_hosts`(正向别名使用默认 known_hosts)。
- 反向隧道用 `RemoteForward <端口> 127.0.0.1:22`(仅回环);多用户盒子上同机其他用户能到达该端口,
  但没有你的私钥无法认证。
- `--yolo` 会绕过审批,**仅在你明确要求时**才启用;opencode 的 `permission:allow` 只写进**本次会话**
  的配置,退出即清。
- 注入的规则是**会话级**的(不写全局文件、不碰挂载的仓库);退出删除会话目录。

### 故障排查

详见 `reference/reverse.md` / `reference/forward.md` 末尾。常见:
- macOS 提示要 macFUSE → 改用 FUSE-T(见[环境要求](#环境要求))。
- 会话中文件突然读不了(`Transport endpoint is not connected`)→ 隧道断了,退出 Agent 后再次启动
  remote-harness,会自动检测陈旧挂载并重挂。
- 挂载报 `not-empty` → 换一个空目录(脚本会提示)。

---

## English

### Table of Contents

- [What it is](#what-it-is)
- [How it works (two directions)](#how-it-works-two-directions)
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
skill with `$remote-harness`. It **interactively confirms every choice** and hands you **one
copy-paste command** to finish. Generically: **A** = the machine the agent runs on; **P** = the
machine the code lives on (an ssh `<alias>`).

### How it works (two directions)

remote-harness **always asks the direction first** (never auto-decides), then confirms each dir:

**① Reverse — agent on a remote box, code on your laptop (behind NAT).** The box can't dial the
laptop, so the laptop opens a **reverse SSH tunnel** and its project is sshfs-mounted onto the box.

```
laptop ~/.ssh/config:  Host <alias>   RemoteForward <PORT> 127.0.0.1:22
        └─ on connect, the box's sshd listens on 127.0.0.1:<PORT> and forwards back to laptop:22
box:   ssh <alias>          → 127.0.0.1:<PORT> → (tunnel) → laptop:22
       sshfs <alias>:/proj  → same tunnel       → laptop files mounted here
```

**② Forward — agent local, code on a directly ssh-reachable server.** No tunnel: the local machine
ssh's straight to the server, mounts its project onto a local empty dir, the agent runs locally, and
builds run on the server via `ssh <alias>`.

Both share the invariant: **mount onto an empty dir → inject "build on `<alias>`" → launch the agent
in the mount.**

### Install

```bash
./manage.sh            # copy-install to ~/.remote-harness + each agent's entry point
./manage.sh --dev      # dev mode: symlink to this repo (edits go live)
./manage.sh --uninstall [claude|codex|opencode]   # uninstall (leaves your ssh config/mounts alone)
```

| Agent | Location | Invoke |
|---|---|---|
| shared core | `~/.remote-harness/{SKILL.md, scripts/, reference/}` | (used by all) |
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
`$remote-harness yolo模式，中文`). It will:

1. **Ask the direction** (reverse / forward; pre-selected from whether you're in an SSH session, but
   always asked).
2. **One-shot preflight** (environment / sshfs+FUSE / tunnel or server reachability) — stops at the
   first missing piece with a fix command.
3. **Confirm each directory** — which code dir, and which empty dir to mount/launch in (candidates +
   free-text).
4. Emit **one copy-paste command**: mount + launch the agent (reverse runs it on the laptop; forward
   on this machine).
5. **Auto-unmounts on exit.** Start remote-harness again anytime to reconnect (idempotent; a stale
   mount is detected and replaced).

### Requirements

- You can already ssh from one machine to the other (any port / common `-J` jump host is fine).
  For complex SSH options (`ProxyCommand`, `-F`, quoted paths with spaces, local forwards, etc.),
  put them in `~/.ssh/config` as a `Host` alias and give remote-harness that alias.
- **Reverse**: the box's sshd allows TCP forwarding (default); the laptop has an SSH server and the
  box's public key in `~/.ssh/authorized_keys` (the script prints the exact key + config line).
- **The machine that does the MOUNT needs `sshfs` + FUSE** — the box (reverse) or your local machine
  (forward):
  - Linux/WSL: `sudo apt-get install -y sshfs` (FUSE usually present; the script gives the right
    per-distro command).
  - **macOS: use FUSE-T — no kernel extension, no reduced system security**:
    `brew install macos-fuse-t/homebrew-cask/fuse-t && brew install macos-fuse-t/homebrew-cask/sshfs-fuse-t`.
    Avoid macFUSE (it requires lowering security). FUSE-T keeps sshfs's synchronous writes, so edits
    land on the host before remote builds. (Kext-less fallback: `rclone nfsmount`, but its writes are
    async — prefer FUSE-T for this edit-here/build-on-host workflow.)

### Repo layout

```
remote-harness/
├── SKILL.md                  # lean entry (overview + interaction rules + direction pick)
├── reference/{reverse,forward,scripts}.md   # per-direction flows + script contracts
├── scripts/                  # deterministic helpers (KEY=VALUE stdout), agent-agnostic
│   ├── _common.sh            # shared lib (colors/ask/sq/parse_via/managed-alias/OS vars)
│   ├── preflight.sh            # one-shot preflight (both directions; --direction forward)
│   ├── detect.sh setup-tunnel.sh connect-guesses.sh check-tunnel.sh  # reverse
│   ├── server-guesses.sh local-setup.sh      # forward
│   ├── laptop-setup.sh                        # reverse orchestrator
│   └── mount-project.sh inject-rule.sh list-projects.sh   # shared by both
├── adapters/{codex,opencode}.md
├── manage.sh
├── AGENTS.md (+ CLAUDE.md symlink)   # guide for agents developing this repo
└── README.md
```

> **Docs convention:** every `*.md` except `README.md` (this file, inline-bilingual) ships a Chinese
> `*.cn.md` counterpart. See `AGENTS.md`.

### Security & privacy

- ssh config is backed up before edits; the reverse tunnel alias uses a dedicated per-alias `known_hosts` (forward uses the default).
- The reverse tunnel binds loopback only (`RemoteForward <PORT> 127.0.0.1:22`); on a multi-user box
  other local users can reach that port but cannot authenticate without your private key.
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
