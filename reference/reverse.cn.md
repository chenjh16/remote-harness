> 中文版。英文原版见 [reverse.md](reverse.md)（以英文版为准）。

# 反向模式 — 代理运行于远端服务器，代码在你的笔记本上

代理运行在**远端服务器**上，代码在用户的**笔记本**上（位于 NAT 后面）。服务器无法主动连接笔记本，因此由笔记本建立**反向 SSH 隧道**，并将笔记本上的项目通过 sshfs 挂载到服务器上。你（代理，在服务器上）负责搭建隧道端点，并向用户输出一条命令，由其在笔记本上运行；`laptop-setup.sh` 会在那边完成剩余的工作。每一个决策都必须遵守 SKILL.md 中的**"确认，不要推断"**原则和跨代理提问工具策略。辅助脚本约定见 `$RH/reference/scripts.cn.md`。

## 反向隧道的工作原理

```
laptop ~/.ssh/config:  Host <alias>   RemoteForward <PORT> 127.0.0.1:22
        └─ on connect, this box's sshd listens on 127.0.0.1:<PORT> and forwards back to laptop:22

this box:  ssh <BOX_ALIAS>          → 127.0.0.1:<PORT> → (tunnel) → laptop:22
           sshfs <BOX_ALIAS>:/path  → same tunnel      → laptop files mounted here
```

笔记本只需在配置中加入 `RemoteForward` 后重新连接即可。`BOX_ALIAS`（例如 `my-mac`）是服务器用来访问笔记本的别名。

## Step 0 — 先识别真实用户（命名空间），再预检

一个服务器账号可能被**多个人共享**，每个人都跑 remote-harness 连回各自的笔记本。为了避免他们的反向隧道相互冲突——更糟的是把 `ssh <alias>` 串到**别人的**笔记本上——我们按**真实用户**给隧道（ssh 别名 + 反向端口）做命名空间隔离。所以先识别这个命名空间，再针对它做预检。

### 0a. 确认命名空间（`RU`）—— 询问，不要推断

```bash
"$RH/scripts/detect.sh"   # REALUSER_GUESS/SOURCE/CANDIDATES、SUGGESTED_PORT（按 RU 稳定哈希）、
                          # LAPTOP_USER_GUESS、DEFAULT_IDENTITY、SSHD_TCP_FORWARDING
```

`REALUSER_GUESS` 是对"你在这个账号上是谁"的尽力猜测，按优先级取自：本次会话登录所用公钥的 comment（需要 sshd `ExposeAuthInfo yes`，默认关闭）、启动目录中 `~/<名字>/…` 的第一层路径名（那个软性的按人约定）、或 authorized_keys 里的 comment。`REALUSER_SOURCE` 说明命中的是哪一个；`REALUSER_CANDIDATES` 列出其余候选。

**向用户提问（确认，不要推断）：** "在这个（可能共享的）账号上，用什么名字给你的隧道做命名空间？"——预填 `REALUSER_GUESS`，并提供 `REALUSER_CANDIDATES` + 其他/自由输入。把答案记作 **`RU`**。你的服务器端别名就是 **`<RU>-mac`**；反向端口由 `RU` 稳定推导。若 `REALUSER_GUESS` 为空（例如你直接从 `$HOME` 启动，或目录是 `work`/`src` 这类通用名），就必须直接询问——没有安全的默认值。

### 0b. 针对你的命名空间做预检

```bash
"$RH/scripts/preflight.sh" --alias <RU>-mac --no-list   # --no-list: 将项目扫描推迟到第 1b.5 步
```

读取 `PREFLIGHT` 的值：

- **`ok`** → 你的命名空间隧道（`<RU>-mac`）已经连回你的笔记本（`TUNNEL_ALIAS`、`TUNNEL_PORT`、
  `LAPTOP_HOSTNAME` 均已就绪）。无需新建 — 立即输出笔记本命令（参见"仅输出"变体一节）。这同时是
  **同一用户、另一个项目**的路径：一条隧道+端口可承载任意多个 sshfs 挂载，所以第二个项目只是在现有隧道上重新挂载——不需要新端口。
- **`blocked`** — 处理 `BLOCKED_STEP`：
  - `tunnel` → 你的 `<RU>-mac` 隧道尚未建立 → 进入 **Step 1**（见下文）。
  - `sshfs` → sshfs/FUSE 缺失：显示 `REMEDY`，提问用户（"已安装？ ✅/⚠️"），
    ✅ 后重新执行；⚠️ 后读取问题并协助解决。循环直至问题解决。

传入 `--alias <RU>-mac` 让预检只考虑你自己的隧道——在共享账号上，它绝不能复用别人的回环别名而把你挂到错误的笔记本上。

`PROJECT_DIR` / `PROJECT_DIR_EMPTY` 用于 Step 1b.5 中**服务器挂载点**的决策（不影响流程是否继续）。挂载点必须为空目录，因为 sshfs 会遮蔽其中的已有文件。

## Step 1 — 搭建隧道并移交给笔记本

### 1a. 配置服务器端（detect 已在 Step 0a 跑过）

若 `SSHD_TCP_FORWARDING=restricted-needs-attention`：提示该服务器的 sshd 阻止了反向转发（`AllowTcpForwarding no|local`）——用户需将其设为 `yes`/`remote` 并重启 sshd。

若 `DEFAULT_IDENTITY` 返回为**空**（这台机器还没有 SSH 密钥），请加上 `--gen-key`，让 `setup-tunnel.sh` 生成一个 ed25519 密钥并输出非空的 `PUBKEY`。否则隧道没有可授权的密钥，后续 Phase 5 登录会卡在密码提示。

```bash
"$RH/scripts/setup-tunnel.sh" \
  --alias     <RU>-mac \
  --namespace <RU> \                # 由 RU 稳定推导反向端口；省略 --port
  --user      <LAPTOP_USER_GUESS> \ # 笔记本登录用户名（与 RU 不同）
  [--identity <DEFAULT_IDENTITY>] \
  [--gen-key]   # 当 DEFAULT_IDENTITY 为空（机器上没有现成密钥）时加上
```

传入 `--namespace <RU>` 并**省略 `--port`**，让端口跟随*已确认*的 `RU`（而不是确认前那个从猜测哈希出来的 `SUGGESTED_PORT`）。`setup-tunnel.sh` 会把 `RU` 哈希到临时端口下界以下的一个稳定 `.22` 槽位，再探测空闲端口。从输出中提取：`ALIAS`（`<RU>-mac`）、`PORT`（推导出的稳定端口——笔记本命令里用它）、`PUBKEY`。若 `PUBKEY` 为空，请加 `--gen-key` 重跑。

### 1b. 询问用户如何连接到本服务器

```bash
"$RH/scripts/connect-guesses.sh"   # candidate ssh commands (user+public/LAN IP)
```

**向用户提问**："你在笔记本上怎么 ssh 进这台服务器？"
- Claude/聊天可以直接展示有用候选。Codex 结构化输入只能放入最佳 2-3 个候选（例如
  `ssh you@203.0.113.10`）；客户端提供的"其他"/自由输入用于填写真实命令。
- "其他"/自由输入示例：`ssh -p 2222 you@203.0.113.20`，或一个普通 SSH config 别名。

从用户回答中提取：
- `CONNECT` = ssh 的*参数部分*（若带有前导 `ssh` 则去掉），
  例如 `-p 2222 you@203.0.113.20`
- `HOST` = 主机/别名部分，例如 `203.0.113.20` 或 `my-box`
- 支持的原始 `CONNECT` 形式包括主机/别名、可选的 `user@host`、`-p`/`-l`/`-i`，以及不需要
  shell 引号的 `-J` / `-o ProxyJump=...`。若需要复杂 SSH 行为（`ProxyCommand`、`-F`、带空格的引号路径、本地转发等），请让用户先写进 `~/.ssh/config` 的 `Host` 别名，然后提供该别名。

### 1b.5 确认两个目录（必须 — 询问用户，不得假设）

输出命令前，先向用户确认（提问用户；检测到的值仅为默认建议，不是最终决定）：

1. **服务器挂载点** — 项目在本服务器上的挂载位置，也是代理的启动目录。选项：
   - "使用当前目录：`<PROJECT_DIR>`" — 仅当目录为空（`PROJECT_DIR_EMPTY=1`）时有效；为空时预先选中此项。→ 传入 `--remote-mountpoint '<PROJECT_DIR>'`。
   - "自动创建 `~/work/<project-name>`（推荐）" — 当前目录非空时预先选中此项。→ **省略** `--remote-mountpoint`（由 laptop-setup 推导）。
   - 其他（用户指定的另一个空目录） → 传入 `--remote-mountpoint '<that dir>'`。
2. **笔记本项目目录** — 要开发的代码库：
   - 若隧道已建立（`PREFLIGHT=ok`）：执行 `"$RH/scripts/list-projects.sh" --via
     <TUNNEL_ALIAS>`，概述候选项，然后提问用户"你笔记本上要开发哪个项目？"。Codex 结构化输入只放最佳 2-3 个路径并保留"其他"/自由输入；Claude/聊天可以展示更长列表。→ 传入 `--project-dir '<LAPTOP_DIR>'`。
   - 若隧道**尚未建立**（你刚在 Step 1 中搭建，还无法访问笔记本）：仍然要求用户手动输入笔记本项目路径。此时无法验证/列出路径，但这仍是必须确认项。→ 传入 `--project-dir '<LAPTOP_DIR>'`。

`laptop-setup.sh` 会在笔记本上验证 `--project-dir`。如果路径不存在或不是目录，它会在合理时询问是否创建，并循环直到用户选择有效目录、成功创建目录或主动中止。若旧版代理省略 `--project-dir`，脚本仍保留笔记本侧交互提示作为兼容兜底；但本 skill 应该传入该参数。

### 1c. 输出笔记本命令 — 完成

按以下格式**原样输出**（短行，`\` 续行，每行不超过 70 个字符）：

```
(
  d=$(mktemp -d "${TMPDIR:-/tmp}/rh.XXXXXX") || exit
  trap 'rm -rf "$d"' EXIT
  ssh -o ClearAllForwardings=yes <CONNECT_ARGS> \
    'cat ~/.remote-harness/scripts/_common.sh' \
    >"$d/_common.sh" &&
  ssh -o ClearAllForwardings=yes <CONNECT_ARGS> \
    'cat ~/.remote-harness/scripts/laptop-setup.sh' \
    >"$d/laptop-setup.sh" &&
  bash "$d/laptop-setup.sh" --host <HOST_Q> --port <PORT> \
    --via <CONNECT_Q> --box-alias <ALIAS_Q> --launch <LAUNCH> \
    [--remote-mountpoint <BOX_MP_Q>] --project-dir <LAPTOP_DIR_Q> [--yolo]
)
```
（两次 fetch 写入同一个临时目录：`laptop-setup.sh` 从同级目录 source `_common.sh`。笔记本通常没有安装任何工具，因此两个文件必须一起 fetch。）
（两次 fetch 必须带 `ClearAllForwardings=yes`：用户的 SSH alias 里可能已经有上次写入的 `RemoteForward`，同端口的陈旧/现有隧道不应该阻止脚本下载。）
Phase 2 中，`laptop-setup.sh` 会确认 `<PORT>` 上的现有监听是否真的连回这台笔记本（hostname + user）。若该端口被另一个或陈旧的隧道占用，它会扫描后续 200 个端口，改写笔记本侧 `RemoteForward`，用 `setup-tunnel.sh` 改写服务器侧 `<ALIAS>`，然后使用第一个空闲端口继续。
（`mktemp` 避免使用可预测的全局可写路径 `/tmp/rh.sh`；子 shell 的 `trap` 会清理临时目录且不掩盖 fetch/setup 的退出码。）
- `[--remote-mountpoint '<BOX_MP>']` = 仅在 **1b.5** 中决定包含时才加入（选择 `~/work/<name>` 默认值时省略）。`--project-dir` 应始终传入。两者均须为用户确认的值，不得使用推测值。
- 每个 `<..._Q>` 占位符都必须使用 `sq()` 语义作为 shell 单词引用，而不是手写简单引号。例如：
  `/Users/O'Neil/app` 应生成 `'/Users/O'\''Neil/app'`。这适用于 `--via`、`--host`、`--box-alias`、`--remote-mountpoint` 和 `--project-dir`。
- `[--yolo]` 仅在用户要求跳过审批时添加。
- `<CONNECT_ARGS>` = 不带前导 `ssh` 的受支持 ssh 参数，例如 `-p 2222 you@203.0.113.20`，用于两次 fetch。`<CONNECT_Q>` 是同一个值的 shell 引用形式，用于 `--via`。不要使用 `eval`；复杂带引号的 SSH 命令必须改用 Host 别名。
- `<LAUNCH>` = 在远端启动的**纯**编程代理 CLI — **即当前运行你（助手）的 CLI**：`claude`（Claude Code）、`codex`（Codex）、`opencode`（opencode）。
  （默认为 `claude`；用你当前正在运行的那个 CLI。）远端服务器必须已安装该 CLI。
  laptop-setup 通过**登录 shell**（`exec "${SHELL:-/bin/bash}" -lic ...`）启动它，因此位于 `~/.local/bin`（由 `~/.profile`/`~/.zshrc` 加入 PATH）的 CLI 无需完整路径即可找到。
- **YOLO / 跳过审批：** 若用户有此请求（参见 SKILL.md 中的"调用选项"），添加 **`--yolo`**。
  `laptop-setup.sh` 会按代理类型应用对应的跳过方式：claude →
  `--dangerously-skip-permissions`；codex → `--dangerously-bypass-approvals-and-sandbox`；opencode →
  仅在**当次会话**配置中写入 `permission:"allow"`（不修改全局配置；退出后即消失）。

告知用户：

> 请在**笔记本上**运行此命令（在本地终端中，不是当前会话）。它将：
> 1. 在专用 harness ssh 别名中添加 RemoteForward 行（不再污染你的普通 ssh 别名）
> 2. 自动重新连接以激活隧道
> 3. 在笔记本上验证已确认的项目目录；若需要修正，会再次提示
> 4. 将其挂载到远端服务器上
> 5. 在远端启动代理 — 你的终端即变为该会话
>    （代理会被告知代码是一个挂载目录，构建/测试/linter 应在你的笔记本上运行）
>
> 退出时，挂载点和隧道将自动销毁。随时再次启动 remote-harness 即可重新连接（Claude Code/opencode 用 `/remote-harness`，Codex 用 `$remote-harness`）。

**你的工作到此结束。** `laptop-setup.sh` 脚本是自包含且交互式的 —
它会在用户的笔记本上自主完成后续流程。**不要**再就目录问题提问用户，也不要等待本会话的进一步确认。

### 仅输出变体（预检时隧道已建立）

若预检返回 `PREFLIGHT=ok`，隧道已存在，但用户可能希望重新挂载或开启新会话。此时仍应输出相同的命令（`laptop-setup.sh` 是幂等的 —— 第一阶段会很快完成，直接读取项目目录并启动代理）。以 `TUNNEL_ALIAS` 作为 `<ALIAS>`，并从现有别名推导 `<CONNECT>` / `<HOST>`，或重新询问用户。

### 故障排查（用户运行命令后报告问题）

- **RemoteForward 端口不可见** → 多路复用主连接被复用：执行 `ssh -O exit <host>`，然后重新连接。
- **普通 `ssh <host>` 出现 `remote port forwarding failed ...`** → 旧版 harness 可能把
  `RemoteForward` 写进了用户的普通 SSH 别名。当前 `laptop-setup.sh` 会创建专用 harness 别名，并在下次运行时移除这条旧配置。临时绕过方式是
  `ssh -o ClearAllForwardings=yes <host>`，或手动删除旧的 `RemoteForward` 行。
- **setup 开始前出现 `remote port forwarding failed for listen port <PORT>`** → 使用了旧命令模板，fetch 脚本时没有 `-o ClearAllForwardings=yes`，SSH 在下载脚本前就尝试申请已有 `RemoteForward`。更新/重新安装本 skill 后重新运行 `$remote-harness`；新命令的 fetch 行会禁用转发。
- **远端端口已监听但 alias 连不回笔记本** → 另一个或陈旧的隧道占用了该端口。当前 `laptop-setup.sh` 会自动尝试下一个空闲端口，并同步更新两端配置。若找不到或无法配置空闲端口，再关闭对应 SSH 会话；若它是多路复用 master，则运行 `ssh -O exit <host>`，然后重试。
- **多个人共用同一个服务器账号** → 每个人在 Step 0a 确认一个各自不同的命名空间 `RU`，于是各自拿到自己的 `<RU>-mac` 别名和一个由 `RU` 哈希出来的反向端口——隧道彼此独立，`ssh <RU>-mac` 永远连回本人自己的笔记本。若两个人不小心确认了**相同**的 `RU`（例如都接受了某个通用猜测），他们的别名/端口就会冲突；重跑 Step 0a 并给出不同的命名空间即可。服务器端 `~/.ssh/config` 的写入用 `flock` 串行化，因此并发的 setup 不会互相覆盖对方的托管块。
- **挂载失败**，`STATUS=failed` → 隧道可能尚未就绪；等待几秒后重试脚本。或在服务器上检查 `BOX_ALIAS` 是否为正确别名（在服务器上执行 `ssh <ALIAS> hostname`）。
- **服务器未安装 sshfs** → 脚本会在用户安装后提示重试（隧道保持不变；无需从 Step 0 重新开始）。
- **启动代理时出现密码提示** → 密钥错误或笔记本上的 sshd 未运行。
- **会话中途文件不可读 / "Transport endpoint is not connected"** → 隧道已断开（例如笔记本休眠），sshfs 挂载变为陈旧状态。退出代理后重新启动 remote-harness（Codex 用 `$remote-harness`）— `laptop-setup` 现在会检测到失效的挂载并重新挂载（不再复用陈旧挂载）。
