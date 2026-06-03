> 中文版。英文原版见 [scripts.md](scripts.md)（以英文版为准）。

# 辅助脚本（参考）

所有脚本均位于 `$RH/scripts/`，其中 `RH="${RH_HOME:-$HOME/.remote-harness}"`。它们在 stdout 输出
`KEY=VALUE`（解析该输出即可），人工提示信息输出至 stderr。

```bash
RH="${RH_HOME:-$HOME/.remote-harness}"
[ -d "$RH/scripts" ] || echo "scripts missing — run: manage.sh"
```

- `"$RH/scripts/preflight.sh"` — 一次性检查；输出 `PREFLIGHT=ok|blocked` 以及 `BLOCKED_STEP`/
  `ERROR`/`REMEDY` + `DIRECTION`。反向模式（默认）：检查隧道及本地 sshfs/FUSE。传入
  `--alias <RU>-mac` 让它只复用该真实用户的命名空间隧道（共享账号上若不传，预检会扫描所有回环别名，
  可能误连到别人的隧道）。正向模式：`--direction forward [--server '<via>']` 检查本地 sshfs/FUSE
  （及服务器可达性）。它**不扫描**用户的项目（流程让用户输入路径；旧的 `--no-list` 现在是 no-op）。请首先运行此脚本。
- `"$RH/scripts/detect.sh"` — 只读探测：`REALUSER_GUESS`/`REALUSER_SOURCE`
  （`authkey|cwd|authorized_keys|none`）/`REALUSER_CANDIDATES`（共享账号上按真实用户的命名空间猜测——
  使用前先确认）、`SUGGESTED_PORT`（由 `REALUSER_GUESS` 哈希到稳定 `.22` 槽位，避免不同用户撞端口；
  无命名空间时退回"最高空闲 `.22`"）、`LAPTOP_USER_GUESS`、`DEFAULT_IDENTITY`、`SSHD_TCP_FORWARDING`、
  `ON_REMOTE`。用于构建隧道时读取。
- `"$RH/scripts/setup-tunnel.sh"` — （反向）在远端机器上写入 `ssh` 别名
  （`<RU>-mac → 127.0.0.1:PORT`）。输出 `ALIAS`、`PORT`、`PUBKEY`、`REMOTEFORWARD_LINE`。幂等操作；
  对共享 `~/.ssh/config` 的写入用 `flock` 串行化，使共享账号上的并发运行不互相覆盖。`--port <PORT>`
  与 `--namespace <RU>` 二选一：给 `--namespace`（且不给 `--port`）时，它按与 `detect.sh` 相同的方式
  从 `RU` 推导稳定端口并探测空闲槽位——传入已确认的 `RU`，使端口跟随它而非确认前的猜测。当机器上没有
  SSH 密钥（`DEFAULT_IDENTITY` 为空）时，传入 `--gen-key` 生成 ed25519 密钥，使 `PUBKEY` 非空。
- `"$RH/scripts/connect-guesses.sh"` — （反向）猜测笔记本电脑访问此机器的方式。
- `"$RH/scripts/check-tunnel.sh"` — （反向）验证监听器并通过隧道进行真实 ssh 登录测试（`--port <PORT>` 检查指定的转发端口）。
- `"$RH/scripts/server-guesses.sh"` — （正向）从 `~/.ssh/config` 非回环别名、known_hosts 及近期历史中
  推测出站 ssh 目标（项目服务器），输出 `ssh <target>` 格式的行。用户自行填写的答案具有最终权威性。
- `"$RH/scripts/list-projects.sh"` — 列出本地候选项目目录，或通过 `--via '<ssh-args|alias>'` 在远端列出。
  **仅按需使用** —— 默认流程**不**扫描用户的项目（慢且带偏，见 SKILL.md "问，别钓"）；让用户输入路径。
  只有当用户明确要求"帮我找"时才用它。输出格式：`PROJECT\t<path>…`。
- `"$RH/scripts/session-cache.sh"` — 在本机记住某命名空间上次的连接选择，让重复运行瞬间推荐（零远程发现）。
  `put <key> KEY=VALUE…` 写入；`get <key>` 打印存的 `KEY=VALUE` 行（无则空）。按命名空间存于
  `$RH_HOME/.sessions-cache/<key>.env`（权限 600）。键用真实用户 `RU`（反向）或服务器标识（正向）；
  流程会缓存 `LAST_PROJECT_DIR`/`LAST_VIA`/`LAST_LOGIN_USER`/`LAST_MOUNTPOINT`/`LAST_LAUNCH`，并据此预填下次提问。
- `"$RH/scripts/mount-project.sh"` — 通过 sshfs 将 `<alias>:<remote-path>` 挂载到本地挂载点
  （方向无关）。拒绝挂载非空目标（`--force` 可覆盖）；对陈旧挂载重新验证/重新挂载；`--unmount` 卸载。
  输出 `STATUS=mounted|already-mounted|need-sshfs|not-empty|failed|unmounted`。
- `"$RH/scripts/local-setup.sh"` — **（正向）在本地机器上运行**：将服务器的稳定 ssh 别名解析出来
  （若为原始参数则创建托管别名），在本地通过 sshfs 挂载服务器项目，注入「在服务器上运行」规则，
  并在挂载目录内本地启动代理；退出时自动卸载。
  参数：`--via '<ssh-args|alias>' --remote-path '<dir>' [--mountpoint '<dir>'] --launch <cli> [--yolo]`。
- `"$RH/scripts/laptop-setup.sh"` — **（反向）在笔记本电脑上运行**：第 1–5 阶段全自动化。
  第 1 阶段：SSH 服务器、授权密钥、RemoteForward 配置。第 2 阶段：重新连接。第 3 阶段：验证项目目录
  （`--project-dir` 提供已确认默认值；无效路径会再次提示）。第 4 阶段：在远端进行 sshfs 挂载（sshfs 缺失或目标非空时交互重试）。
  第 5 阶段：注入「在笔记本上运行」规则，然后启动所选代理（`--launch`，默认为 `claude`）。
- `"$RH/scripts/inject-rule.sh"` — **在代理运行的机器上执行**（反向为远端机器，正向为本地机器），方向无关：
  `on <agent> <code_path> <host_alias> <mountpoint> [yolo]` 在 `$RH_HOME/.sessions/<key>` 下构建
  **会话级**产物，并打印启动方式，确保**仅本次会话**读取该规则——**不修改任何全局配置，也不写入已挂载的仓库**。
  输出 `RH_STATUS`、`RH_LAUNCH_ENV`、`RH_LAUNCH_FLAGS`：
    - claude   → `RH_LAUNCH_FLAGS=--append-system-prompt-file '<rule>'`（会话标志）
    - opencode → `RH_LAUNCH_ENV=OPENCODE_CONFIG='<session cfg>'`（含指令；若指定 yolo 则追加 `permission:"allow"`）
    - codex    → `RH_LAUNCH_FLAGS=-c 'developer_instructions="<rule>"'`（会话级 CLI 配置；
      保留真实 `CODEX_HOME`，因此 keyring 存储的 ChatGPT 登录态仍可用）。非 yolo 时还会带
      `-s workspace-write -c sandbox_workspace_write.network_access=true
      -c 'sandbox_workspace_write.writable_roots=["~/.ssh"]'`，使沙箱放行规则要求的出站 ssh，并允许 ssh 在
      `~/.ssh` 下写入 ControlMaster socket / known_hosts——必须带 `-s`，否则默认模式下该子表会被忽略。
      对于重度/长时间的 codex 会话，`$remote-harness yolo模式，中文`（直接关掉沙箱）仍是最省心的。）
  规则内容：声明当前工作目录是 `<host_alias>` 上 `<code_path>` 的 sshfs 挂载，并要求通过
  `ssh <host_alias> 'cd <code_path> && <cmd>'` 在 `<host_alias>` 上运行构建/测试/lint/安装/应用
  （绝不在「本机」运行），同时附有从项目清单嗅探出的**针对技术栈的示例命令**。两个安装脚本均会将
  `RH_LAUNCH_ENV`/`RH_LAUNCH_FLAGS` 注入启动命令，并在退出时调用
  `off <agent> <mountpoint>`（删除会话目录）。
- `"$RH/scripts/_common.sh"` — 被两个安装脚本共同 source 的共享工具函数（颜色、`ask`、`sq`、
  `parse_via`、`write_managed_alias`、OS 变量）。当 setup 脚本写入托管 ssh 别名时，`parse_via`
  会保留 user/port/identity 以及 `ProxyJump`（`-J` / `-o ProxyJump=...`）。它会有意拒绝无法安全保留的原始 SSH 语义（`ProxyCommand`、`-F`、本地转发、带空格的引号 token 等）；这类用法应先写进 `~/.ssh/config` 的 `Host` 别名，再传入该别名。非入口点。
