> 中文版。英文原版见 [scripts.md](scripts.md)（以英文版为准）。

# 辅助脚本（参考）

所有脚本均位于 `$RH/scripts/`，其中 `RH="${RH_HOME:-$HOME/.remote-harness}"`。它们在 stdout 输出
`KEY=VALUE`（解析该输出即可），人工提示信息输出至 stderr。

```bash
RH="${RH_HOME:-$HOME/.remote-harness}"
[ -d "$RH/scripts" ] || echo "scripts missing — run: manage.sh"
```

- `"$RH/scripts/preflight.sh"` — **legacy/诊断专用**。当前 simple reverse/forward 不调用它；分模式
  setup 脚本会创建会话级 SSH config 并执行自己的定向检查。它仍为旧 runbook 或专项调试输出
  `PREFLIGHT=ok|blocked`、`BLOCKED_STEP`/`ERROR`/`REMEDY` 和 `DIRECTION`。反向诊断只检查显式
  `--alias` 或 `~/.ssh/config` 中已有的历史回环别名；除非手动传入 alias，否则它不理解新的 simple
  会话级别名。正向模式：`--direction forward [--server '<via>']` 检查本地 sshfs/FUSE（及服务器可达性）。
  它**不扫描**用户的项目。
- `"$RH/scripts/simple-bootstrap.sh"` — **公开统一 simple 入口，在本地机器运行**。若从本地安装运行，
  它会直接移交给 `simple-dispatch.sh`。若从远端 skill/source 安装目录 pipe 到本地运行，它会使用
  `--via`/`RH_VIA` 抓取 `_common.sh`、`simple-dispatch.sh`、两个 simple 向导及其本地依赖到临时目录，
  再移交给抓取到的 dispatcher。明确模式时传 `--mode reverse` 或 `--mode forward`；无法判断时省略
  `--mode`，由本地提示选择。skill 命令模板要紧凑但可复制：使用较少的短行，远端
  `ssh ... | bash ...` 管道保持为可读续行。它会把脚本来源的 `LAST_VIA` 写入本地
  `~/.remote-harness/simple-cache.env`。
- `"$RH/scripts/suggest-via.sh"` — **simple reverse 远端侧 SSH target 默认值辅助脚本**。它在 Agent
  回复前运行在远端机器上，输出 `STATUS`、`VIA` 和 `SOURCE`。它可以使用远端用户名、服务器地址和服务器
  SSH 端口。若读取 `SSH_CONNECTION`，只能使用第 3/4 字段（`server-ip` / `server-port`），绝不输出
  第 1/2 字段，因为那是本地客户端数据。`VIA` 只是可编辑提示默认值；本地 `LAST_VIA` 缓存优先。
- `"$RH/scripts/simple-laptop-setup.sh"` — **simple reverse 本地向导**。它在本地提示输入远端
  笔记本项目目录、可选远端挂载点和启动偏好。它使用固定会话别名 `rlocal`，并只通过
  `setup-tunnel.sh --config <临时config> --namespace rlocal --alias rlocal --gen-key` 写入远端临时 ssh config；
  随后带着 `--box-ssh-config`、`--project-dir`、`--box-alias`、`--port` 和选定的 `--launch` 调用
  `laptop-setup.sh`。生成的 remote-harness 公钥会交给 `laptop-setup.sh` 做范围受限的临时授权。
  它会把确认过的默认值写入同一个本地缓存文件，供下次使用。
- `"$RH/scripts/simple-local-setup.sh"` — **simple forward 本地向导**。它在本地提示服务器 SSH
  target、服务器项目目录、可选本地挂载点和启动偏好。它把确认过的默认值保存到
  `~/.remote-harness/simple-forward-cache.env`，然后调用 `local-setup.sh`。启动后的 Agent 在本地挂载目录
  中编辑/搜索文件，项目命令通过注入规则走 SSH 到服务器执行。
- `"$RH/scripts/simple-dispatch.sh"` — **simple 本地模式分发器**。它接受显式
  `--mode reverse|forward`；省略 `--mode` 时在本地提示 reverse 或 forward，第一次默认 reverse，把
  `LAST_MODE` 缓存在 `~/.remote-harness/simple-mode-cache.env`，然后移交给
  `simple-laptop-setup.sh` 或 `simple-local-setup.sh`。私有参数 `--source-via` 由
  `simple-bootstrap.sh` 传入，只在 reverse 模式下复用。
- `"$RH/scripts/detect.sh"` — **legacy/兼容只读探测**。simple 主路径不再让 Agent 推断 namespace；
  `setup-tunnel.sh --namespace` 负责稳定端口推导。该脚本保留给测试和旧诊断：`REALUSER_GUESS`/`REALUSER_SOURCE`
  （`authkey|cwd|authorized_keys|none`）/`REALUSER_CANDIDATES`（共享账号上按真实用户的命名空间猜测——
  使用前先确认）、`SUGGESTED_PORT`（由 `REALUSER_GUESS` 哈希到稳定 `.22` 槽位，避免不同用户撞端口；
  无命名空间时退回旧的"最高空闲 `.22`"兜底）、`LAPTOP_USER_GUESS`、`DEFAULT_IDENTITY`、`SSHD_TCP_FORWARDING`、
  `ON_REMOTE`。它不得输出本地 client IP/端口。
- `"$RH/scripts/setup-tunnel.sh"` — （反向）只把远端回连笔记本的 `ssh` 别名写入**会话级临时 config**
  （必须传 `--config <绝对路径>`）。输出 `ALIAS`、`PORT`、`CONFIG`、`PUBKEY`、
  `REMOTEFORWARD_LINE`，以及与 session config 同目录的 `KNOWN_HOSTS` 路径。它不会写
  `~/.ssh` 下任何内容。
  `--port <PORT>` 与 `--namespace <RU>` 二选一：给 `--namespace`（且不给 `--port`）时，它按与
  `detect.sh` 相同的方式从 `RU` 推导稳定端口并探测空闲槽位。手动传入 `--gen-key` 时会在
  `$RH_HOME/keys` 下生成 ed25519 密钥，使 `PUBKEY` 非空；simple reverse 会自动请求它，以便本地追加
  范围受限的临时 `authorized_keys` 授权。
- `"$RH/scripts/connect-guesses.sh"` — **legacy/按需**反向 SSH target 猜测 helper。当前 simple 主路径使用
  `suggest-via.sh` 生成范围更窄的服务器侧默认值。
- `"$RH/scripts/check-tunnel.sh"` — （反向）验证监听器并通过隧道进行真实 ssh 登录测试（`--port <PORT>` 检查指定的转发端口）。
- `"$RH/scripts/server-guesses.sh"` — **仅按需使用**的 forward SSH target 建议 helper。默认 simple forward
  向导会让用户输入服务器 target，并用本地缓存作为默认；除非用户明确要求建议，否则不扫描
  `~/.ssh/config`、known_hosts 或 shell history。
- `"$RH/scripts/list-projects.sh"` — 列出本地候选项目目录，或通过 `--via '<ssh-args|alias>'` 在远端列出。
  **仅按需使用** —— 默认流程**不**扫描用户的项目（慢且带偏，见 SKILL.md "问，别钓"）；让用户输入路径。
  只有当用户明确要求"帮我找"时才用它。输出格式：`PROJECT\t<path>…`。
- `"$RH/scripts/session-cache.sh"` — **legacy 通用缓存 helper**。当前 simple 脚本改用专门的本地缓存文件
  （`simple-cache.env`、`simple-forward-cache.env`、`simple-mode-cache.env`），让用户在终端向导里看到默认值，
  不需要 Agent 参与。该 helper 仅保留给旧集成或显式工具调用。
- `"$RH/scripts/mount-project.sh"` — 通过 sshfs 将 `<alias>:<remote-path>` 挂载到本地挂载点
  （方向无关）。拒绝挂载非空目标（`--force` 可覆盖）；对陈旧挂载重新验证/重新挂载；`--unmount` 卸载。
  输出 `STATUS=mounted|already-mounted|need-sshfs|not-empty|failed|unmounted`。
- `"$RH/scripts/local-setup.sh"` — **（正向）在本地机器上运行**：通过会话级 ssh config 解析服务器的稳定
  ssh 别名（若为原始参数则创建会话级别名），在本地通过 sshfs 挂载服务器项目，注入「在服务器上运行」规则，
  并在挂载目录内本地启动代理；退出时自动卸载并删除临时 config。它不会写本地 `~/.ssh`。
  参数：`--via '<ssh-args|alias>' --remote-path '<dir>' [--mountpoint '<dir>'] --launch <cli> [--yolo]`。
- `"$RH/scripts/laptop-setup.sh"` — **（反向）在笔记本电脑上运行**：第 1–5 阶段全自动化。
  第 1 阶段：SSH 服务器、授权密钥，以及本地
  `~/.remote-harness/.sessions/.../ssh_config` 下的**会话级** RemoteForward 配置。
  第 2 阶段：通过内部 ssh wrapper 重新连接。第 3 阶段：验证项目目录（`--project-dir` 提供已确认默认值；
  无效路径会再次提示）。第 4 阶段：在远端进行 sshfs 挂载（sshfs 缺失或目标非空时交互重试）。
  第 5 阶段：注入「在笔记本上运行」规则，然后启动所选代理（`--launch`，默认为 `claude`）。
  完整会话必须传 `--box-ssh-config`；`--setup-only` 可省略。它不会写本地 `~/.ssh/config`、`known_hosts`
  或 SSH key。完整 reverse 会话中若提供 `--pubkey`，它可以向本地 `~/.ssh/authorized_keys` 追加带
  `remote-harness:reverse-auth:<tag>` 标签、仅限回环来源且可引用计数清理的托管块。
- `"$RH/scripts/inject-rule.sh"` — **在代理运行的机器上执行**（反向为远端机器，正向为本地机器），方向无关：
  `on <agent> <code_path> <host_alias> <mountpoint> [yolo]` 在 `$RH_HOME/.sessions/<key>` 下构建
  **会话级**产物，并打印启动方式，确保**仅本次会话**读取该规则——**不修改任何全局配置，也不写入已挂载的仓库**。
  输出 `RH_STATUS`、`RH_LAUNCH_ENV`、`RH_LAUNCH_FLAGS`：
    - claude   → `RH_LAUNCH_FLAGS=--append-system-prompt-file '<rule>'`（会话标志）
    - opencode → `RH_LAUNCH_ENV=OPENCODE_CONFIG='<session cfg>'`（含指令；若指定 yolo 则追加 `permission:"allow"`）
    - codex    → `RH_LAUNCH_FLAGS=-c 'developer_instructions="<rule>"'`（会话级 CLI 配置；
      保留真实 `CODEX_HOME`，因此 keyring 存储的 ChatGPT 登录态仍可用）。非 yolo 时还会带
      `-s workspace-write -c sandbox_workspace_write.network_access=true`，并只把相关
      `~/.remote-harness/.sessions/...` 目录加入 writable roots，使沙箱放行规则要求的出站 ssh，并允许 ssh
      在那里写入临时 ControlPath/known_hosts；它绝不会把 `~/.ssh` 设为可写。必须带 `-s`，否则默认模式下该子表会被忽略。
      对于重度/长时间的 codex 会话，`$remote-harness yolo模式，中文`（直接关掉沙箱）仍是最省心的。）
  规则内容：声明当前工作目录是 `<host_alias>` 上 `<code_path>` 的 sshfs 挂载，并要求通过
  `ssh <host_alias> 'cd <code_path> && <cmd>'` 在 `<host_alias>` 上运行构建/测试/lint/安装/应用
  （绝不在「本机」运行），同时附有从项目清单嗅探出的**针对技术栈的示例命令**。两个安装脚本均会将
  `RH_LAUNCH_ENV`/`RH_LAUNCH_FLAGS` 注入启动命令，并在退出时调用
  `off <agent> <mountpoint>`（删除会话目录）。
- `"$RH/scripts/_common.sh"` — 被两个安装脚本共同 source 的共享工具函数（颜色、`ask`、`sq`、
  `parse_via`、`write_managed_alias`、OS 变量）。当 setup 脚本写入托管 ssh 别名时，`parse_via`
  会保留 user/port/identity 以及 `ProxyJump`（`-J` / `-o ProxyJump=...`）。它会有意拒绝无法安全保留的原始 SSH 语义（`ProxyCommand`、`-F`、本地转发、带空格的引号 token 等）；这类用法应先写进 `~/.ssh/config` 的 `Host` 别名，再传入该别名。非入口点。
