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

## 速度原则：问，别钓

这个流程必须**快** —— 问几个问题，笔记本命令就好了。两条硬规则：

- **绝不通过远程搜索去发现用户的项目。** 不要跑 `list-projects.sh --via`，也不要 `ssh <alias> 'find …'`/`ls` 去找笔记本上的项目。它慢，而且经常**带偏** —— 项目可能在一个和你猜测**不同的笔记本账户**下（比如隧道是 `chenjh` 的，项目却在 `/Users/substance/…`）。让用户输入路径；`laptop-setup.sh` 会在笔记本端校验并在出错时重提示。
- **推荐只能来自便宜的本地/缓存信号**，并永远提供"自己输入"：按命名空间的缓存（`session-cache.sh`）、本机 `~/.ssh/config`、cwd、以及 `connect-guesses.sh`。本地**只探测一次**，然后把问题合并提问。

一个服务器账号也可能被**多个人共享**，各自连回自己的笔记本——所以隧道（ssh 别名 + 反向端口）按**真实用户**（`RU`）做命名空间隔离；确认 `RU` 是下面合并提问中的一项。

## Step 0 — 一次本地探测（单个 Bash 调用；每个脚本只跑一遍）

```bash
RH="${RH_HOME:-$HOME/.remote-harness}"
"$RH/scripts/detect.sh"                                 # REALUSER_GUESS/SOURCE/CANDIDATES、SUGGESTED_PORT、DEFAULT_IDENTITY、SSHD_TCP_FORWARDING
"$RH/scripts/connect-guesses.sh"                        # 笔记本→盒子的候选 `ssh …` 串
"$RH/scripts/session-cache.sh" get "<REALUSER_GUESS>"   # LAST_PROJECT_DIR/LAST_VIA/LAST_LOGIN_USER/LAST_MOUNTPOINT（首次为空）
"$RH/scripts/preflight.sh" --alias "<REALUSER_GUESS>-mac" --no-list   # 隧道通了吗？+ sshfs/FUSE + PROJECT_DIR/PROJECT_DIR_EMPTY（cwd）
```

把四个放进**一个** Bash 块跑，解析 stdout（`KEY=VALUE`）。别为了"看 stderr"把脚本跑两遍——stderr 只是人工提示。`<REALUSER_GUESS>` 来自 `detect.sh`；若它**为空**，本次探测就去掉 `session-cache get` 和 `preflight --alias` 两行（还没有命名空间），先在 Step 1 确认 `RU`，再跑一次 `preflight --alias <RU>-mac`。读取：

- `SSHD_TCP_FORWARDING=restricted-needs-attention` → 提示盒子 sshd 阻止反向转发（`AllowTcpForwarding no|local`）；用户需设 `yes`/`remote` 并重启 sshd。
- `PREFLIGHT=ok` → 你的 `<RU>-mac` 隧道已连回你的笔记本（`TUNNEL_ALIAS`、`TUNNEL_PORT`、`LAPTOP_HOSTNAME`/`LAPTOP_USER`）。这是**复用**路径（含同一用户/另一个项目——一条隧道承载任意多挂载）：无需新建隧道，确认几个值后走"仅输出"。
- `PREFLIGHT=blocked` + `BLOCKED_STEP=sshfs` → 显示 `REMEDY`，提问（"已安装？ ✅/⚠️"），✅ 后重跑。`BLOCKED_STEP=tunnel` → 在 Step 2 建。
- 出现 `LAST_*` → 该命名空间有过历史会话；把它们当作下面的**预填默认值**，重复运行近乎一键。

（`--alias <RU>-mac` 让预检只考虑你自己的隧道——在共享账号上绝不能复用别人的回环别名而挂到错误的笔记本。挂载点必须为空，因为 sshfs 会遮蔽已有文件。）

## Step 1 — 确认方向，然后一轮合并提问

先确认**方向**（检测只预选：`SSH_CONNECTION` 已设 / `ON_REMOTE=1` ⇒ 反向）。然后把反向的几个决策**一起**问（AskUserQuestion 最多 4 个）——每项都用 Step 0 的结果预填，每项都带自由输入"其他"。重复运行（命中缓存）时大多是一键确认。

1. **命名空间 `RU`** —— 预填 `REALUSER_GUESS`；提供 `REALUSER_CANDIDATES` + 其他。盒子别名是 `<RU>-mac`，反向端口由 `RU` 稳定哈希。（猜测为空 ⇒ 无安全默认，直接问。）
2. **笔记本项目目录** —— 要开发的代码库。有缓存就预填 `LAST_PROJECT_DIR`；否则让用户**输入绝对路径**（如 `/Users/you/proj`）。**绝不扫描、绝不用搜索去找。** → `--project-dir`。
3. **盒子挂载点** —— 在本机的挂载位置，也是代理启动目录。**仅当为空**才推荐 cwd：`PROJECT_DIR_EMPTY=1` ⇒ 预选"使用当前目录：`<PROJECT_DIR>`" → 传 `--remote-mountpoint '<PROJECT_DIR>'`。否则推荐自动 `~/work/<basename>`（**省略** `--remote-mountpoint`），或让用户输入另一个空目录。
4. **连接串** —— 笔记本怎么 SSH 进本机（隧道据此反拨）。有缓存预填 `LAST_VIA`，否则用 `connect-guesses.sh` 最佳候选；+ 其他（如 `-p 2222 you@203.0.113.20`，或一个 `~/.ssh/config` 别名）。提取 `CONNECT` = 去掉前导 `ssh` 的参数，`HOST` = 主机/别名。支持的原始形式：主机/别名、`user@host`、`-p`/`-l`/`-i`、`-J`/`-o ProxyJump=…`（无需 shell 引号）；遇 `ProxyCommand`/`-F`/带空格引号，让用户写进 `~/.ssh/config` 的 Host 别名再传。

**笔记本登录用户**（`LOGIN_USER`，用于把项目 sshfs 挂回来）—— 能推导就**不要**单独开一个问题：`LAST_LOGIN_USER`（缓存）→ 否则取已确认**项目目录**的 `/Users/<x>/` 或 `/home/<x>/` 第一层 → 否则连接串里的用户 → 否则 `LAPTOP_USER_GUESS`。只有当它们**冲突**时才提问——比如项目在 `/Users/substance/…` 但连接用户是 `chenjh`，这种不一致会导致挂载失败（登录用户读不了别人的家目录），出命令前要点出来让用户对齐。

`laptop-setup.sh` 会在笔记本端校验 `--project-dir` 并在缺失/读不到时循环提示——所以输入的路径是安全的，你不必从盒子端去验证它。

## Step 2 — 配置盒子端，然后记住选择

若 `PREFLIGHT=ok` 且已确认的项目 + `LOGIN_USER` 和现有隧道一致，跳到"仅输出"变体。否则配置盒子端（`DEFAULT_IDENTITY` 为空时加 `--gen-key`——没有盒子密钥，后续 Phase 5 登录会卡密码）：

```bash
"$RH/scripts/setup-tunnel.sh" \
  --alias     <RU>-mac \
  --namespace <RU> \                # 由 RU 稳定推导反向端口；省略 --port
  --user      <LOGIN_USER> \        # 推导/确认出的笔记本登录用户
  [--identity <DEFAULT_IDENTITY>] \
  [--gen-key]
```

提取 `ALIAS`（`<RU>-mac`）、`PORT`（稳定端口——笔记本命令里用它）、`PUBKEY`（为空则加 `--gen-key` 重跑）。

然后**记住**这些选择，让该命名空间下次运行瞬间预填——**两条路径**（新建和仅输出）都要在出命令前跑：

```bash
"$RH/scripts/session-cache.sh" put <RU> \
  "LAST_PROJECT_DIR=<LAPTOP_DIR>" "LAST_VIA=<CONNECT>" "LAST_LOGIN_USER=<LOGIN_USER>" \
  "LAST_MOUNTPOINT=<BOX_MP>" "LAST_LAUNCH=<LAUNCH>"
```

## Step 3 — 输出笔记本命令 — 完成

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
- `[--remote-mountpoint '<BOX_MP>']` = 仅在 **Step 1** 中决定使用显式挂载点时才加入（选择 `~/work/<name>` 默认值时省略）。`--project-dir` 应始终传入。两者均须为用户确认的值，不得使用推测值。
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

若预检返回 `PREFLIGHT=ok`，隧道已存在，但用户可能希望重新挂载或开启新会话。此时仍输出相同的命令（`laptop-setup.sh` 是幂等的 —— 第一阶段会很快完成，直接读取项目目录并启动代理）。以 `TUNNEL_ALIAS` 作为 `<ALIAS>`、现有的 `TUNNEL_PORT` 作为 `<PORT>`。`<CONNECT>` / `<HOST>` 有缓存的 `LAST_VIA` 就预填——只有在没有缓存连接串时才重新询问。出命令前仍要跑 Step 2 里的 `session-cache.sh put` 以保持缓存最新。

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
