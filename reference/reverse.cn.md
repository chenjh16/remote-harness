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

## Step 0 — 预检（一次调用，一个决策）

```bash
"$RH/scripts/preflight.sh" --no-list   # --no-list: 将项目扫描推迟到第 1b.5 步（仅在隧道确认可用后执行）
```

读取 `PREFLIGHT` 的值：

- **`ok`** → 隧道已正常工作（`TUNNEL_ALIAS`、`TUNNEL_PORT`、`LAPTOP_HOSTNAME` 均已就绪）。
  隧道已建立 — 立即输出笔记本命令（参见"仅输出"变体一节）。
- **`blocked`** — 处理 `BLOCKED_STEP`：
  - `tunnel` → 没有可用的回程通道 → 进入 **Step 1**（见下文）。
  - `sshfs` → sshfs/FUSE 缺失：显示 `REMEDY`，提问用户（"已安装？ ✅/⚠️"），
    ✅ 后重新执行；⚠️ 后读取问题并协助解决。循环直至问题解决。

`PROJECT_DIR` / `PROJECT_DIR_EMPTY` 用于 Step 1b.5 中**服务器挂载点**的决策（不影响流程是否继续）。挂载点必须为空目录，因为 sshfs 会遮蔽其中的已有文件。

## Step 1 — 搭建隧道并移交给笔记本

### 1a. 配置服务器端

```bash
"$RH/scripts/detect.sh"   # get SUGGESTED_PORT, LAPTOP_USER_GUESS, DEFAULT_IDENTITY
```

若 `SSHD_TCP_FORWARDING=restricted-needs-attention`：提示该服务器的 sshd 阻止了反向转发（`AllowTcpForwarding no|local`）——用户需将其设为 `yes`/`remote` 并重启 sshd。

若 `DEFAULT_IDENTITY` 返回为**空**（这台机器还没有 SSH 密钥），请加上 `--gen-key`，让 `setup-tunnel.sh` 生成一个 ed25519 密钥并输出非空的 `PUBKEY`。否则隧道没有可授权的密钥，后续 Phase 5 登录会卡在密码提示。

```bash
"$RH/scripts/setup-tunnel.sh" \
  --alias <LAPTOP_USER_GUESS>-mac \
  --port  <SUGGESTED_PORT> \
  --user  <LAPTOP_USER_GUESS> \
  [--identity <DEFAULT_IDENTITY>] \
  [--gen-key]   # 当 DEFAULT_IDENTITY 为空（机器上没有现成密钥）时加上
```

从输出中提取：`ALIAS`（服务器端别名，例如 `my-mac`）、`PORT`、`PUBKEY`。若 `PUBKEY` 为空，请加 `--gen-key` 重跑。

### 1b. 询问用户如何连接到本服务器

```bash
"$RH/scripts/connect-guesses.sh"   # candidate ssh commands (user+public/LAN IP)
```

**向用户提问**："你在笔记本上怎么 ssh 进这台服务器？"
- 将每个候选项作为选项列出（例如 `ssh you@203.0.113.10`）
- 加上"其他"（自由输入实际使用的命令，例如 `ssh -p 2222 you@203.0.113.20`）

从用户回答中提取：
- `CONNECT` = ssh 的*参数部分*（若带有前导 `ssh` 则去掉），
  例如 `-p 2222 you@203.0.113.20`
- `HOST` = 主机/别名部分，例如 `203.0.113.20` 或 `my-box`

### 1b.5 确认两个目录（必须 — 询问用户，不得假设）

输出命令前，先向用户确认（提问用户；检测到的值仅为默认建议，不是最终决定）：

1. **服务器挂载点** — 项目在本服务器上的挂载位置，也是代理的启动目录。选项：
   - "使用当前目录：`<PROJECT_DIR>`" — 仅当目录为空（`PROJECT_DIR_EMPTY=1`）时有效；为空时预先选中此项。→ 传入 `--remote-mountpoint '<PROJECT_DIR>'`。
   - "自动创建 `~/work/<project-name>`（推荐）" — 当前目录非空时预先选中此项。→ **省略** `--remote-mountpoint`（由 laptop-setup 推导）。
   - 其他（用户指定的另一个空目录） → 传入 `--remote-mountpoint '<that dir>'`。
2. **笔记本项目目录** — 要开发的代码库：
   - 若隧道已建立（`PREFLIGHT=ok`）：执行 `"$RH/scripts/list-projects.sh" --via
     <TUNNEL_ALIAS>`，然后提问用户"你笔记本上要开发哪个项目？"（每个路径作为选项，加"其他"自由输入）。→ 传入 `--project-dir '<LAPTOP_DIR>'`。
   - 若隧道**尚未建立**（你刚在 Step 1 中搭建，还无法访问笔记本）：**省略** `--project-dir`，并告知用户该命令会在运行时提示输入笔记本项目目录（那个 readline 提示本身就是确认步骤）。

### 1c. 输出笔记本命令 — 完成

按以下格式**原样输出**（短行，`\` 续行，每行不超过 70 个字符）：

```
d=$(mktemp -d "${TMPDIR:-/tmp}/rh.XXXXXX") \
  && ssh <CONNECT> 'cat ~/.remote-harness/scripts/_common.sh'     >"$d/_common.sh" \
  && ssh <CONNECT> 'cat ~/.remote-harness/scripts/laptop-setup.sh' >"$d/laptop-setup.sh" \
  && bash "$d/laptop-setup.sh" --host <HOST> --port <PORT> --via '<CONNECT>' \
       --box-alias <ALIAS> --launch <LAUNCH> \
       [--remote-mountpoint '<BOX_MP>'] [--project-dir '<LAPTOP_DIR>'] [--yolo]; rm -rf "$d"
```
（两次 fetch 写入同一个临时目录：`laptop-setup.sh` 从同级目录 source `_common.sh`。笔记本通常没有安装任何工具，因此两个文件必须一起 fetch。）
（`mktemp` 避免使用可预测的全局可写路径 `/tmp/rh.sh`，并以 0600 权限创建文件。）
- `[--remote-mountpoint '<BOX_MP>']` / `[--project-dir '<LAPTOP_DIR>']` = 仅在 **1b.5** 中决定包含时才加入（若选择 `~/work/<name>` 默认值，或笔记本目录留待本地提示时，则省略）。两者均须为用户确认的值，不得使用推测值。
- `[--yolo]` 仅在用户要求跳过审批时添加。
- `<CONNECT>` = 不带前导 `ssh` 的 ssh 参数，例如 `-p 2222 you@203.0.113.20`。
  传给初始 `ssh` 调用和 `--via` 的值必须完全一致。
- `<LAUNCH>` = 在远端启动的**纯**编程代理 CLI — **即当前运行你（助手）的 CLI**：`claude`（Claude Code）、`codex`（Codex）、`opencode`（opencode）。
  （默认为 `claude`；用你当前正在运行的那个 CLI。）远端服务器必须已安装该 CLI。
  laptop-setup 通过**登录 shell**（`exec "${SHELL:-/bin/bash}" -lic ...`）启动它，因此位于 `~/.local/bin`（由 `~/.profile`/`~/.zshrc` 加入 PATH）的 CLI 无需完整路径即可找到。
- **YOLO / 跳过审批：** 若用户有此请求（参见 SKILL.md 中的"调用选项"），添加 **`--yolo`**。
  `laptop-setup.sh` 会按代理类型应用对应的跳过方式：claude →
  `--dangerously-skip-permissions`；codex → `--dangerously-bypass-approvals-and-sandbox`；opencode →
  仅在**当次会话**配置中写入 `permission:"allow"`（不修改全局配置；退出后即消失）。

告知用户：

> 请在**笔记本上**运行此命令（在本地终端中，不是当前会话）。它将：
> 1. 在你的 ssh 配置中添加 RemoteForward 行（如有需要，创建 `<BOX_USER>-remote` 别名）
> 2. 自动重新连接以激活隧道
> 3. 提示你输入要开发的项目目录（默认为当前目录；按 Enter 接受）
> 4. 将其挂载到远端服务器上
> 5. 在远端启动代理 — 你的终端即变为该会话
>    （代理会被告知代码是一个挂载目录，构建/测试/linter 应在你的笔记本上运行）
>
> 退出时，挂载点和隧道将自动销毁。随时运行 `/remote-harness` 即可重新连接。

**你的工作到此结束。** `laptop-setup.sh` 脚本是自包含且交互式的 —
它会在用户的笔记本上自主完成后续流程。**不要**再就目录问题提问用户，也不要等待本会话的进一步确认。

### 仅输出变体（预检时隧道已建立）

若预检返回 `PREFLIGHT=ok`，隧道已存在，但用户可能希望重新挂载或开启新会话。此时仍应输出相同的命令（`laptop-setup.sh` 是幂等的 —— 第一阶段会很快完成，直接读取项目目录并启动代理）。以 `TUNNEL_ALIAS` 作为 `<ALIAS>`，并从现有别名推导 `<CONNECT>` / `<HOST>`，或重新询问用户。

### 故障排查（用户运行命令后报告问题）

- **RemoteForward 端口不可见** → 多路复用主连接被复用：执行 `ssh -O exit <host>`，然后重新连接。
- **挂载失败**，`STATUS=failed` → 隧道可能尚未就绪；等待几秒后重试脚本。或在服务器上检查 `BOX_ALIAS` 是否为正确别名（在服务器上执行 `ssh <ALIAS> hostname`）。
- **服务器未安装 sshfs** → 脚本会在用户安装后提示重试（隧道保持不变；无需从 Step 0 重新开始）。
- **启动代理时出现密码提示** → 密钥错误或笔记本上的 sshd 未运行。
- **会话中途文件不可读 / "Transport endpoint is not connected"** → 隧道已断开（例如笔记本休眠），sshfs 挂载变为陈旧状态。退出代理后重新运行 `/remote-harness` — `laptop-setup` 现在会检测到失效的挂载并重新挂载（不再复用陈旧挂载）。
