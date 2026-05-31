> 中文版。英文原版见 [forward.md](forward.md)（以英文版为准）。

# 正向模式 — Agent 在本地，代码位于可直接 ssh 到的远程服务器

Agent（即你）运行在用户的**本地机器**上；项目位于本机可直接 ssh 访问的远程服务器。无需隧道——所有操作均在本机和直连 ssh 之间进行，因此技能和生成的命令都在**本机**执行。保持一贯的、由提问工具把关的连续流程（遵守 SKILL.md 中的**"确认，不要推断"**原则和跨代理提问工具策略）；合法的暂停点只有 sshfs 安装检查和最终的移交。辅助脚本契约见 `$RH/reference/scripts.cn.md`。

## F-0 — 预检（本地）

```bash
"$RH/scripts/preflight.sh" --direction forward --no-list
```
- `BLOCKED_STEP=sshfs` → 显示与操作系统对应的 `REMEDY`，AskUserQuestion（"已安装？✅/⚠️"），✅ 后重新运行。循环直至 `PREFLIGHT=ok`。（`PROJECT_DIR_EMPTY` 为本地当前工作目录；决定 F-2.5 中的挂载点。）

## F-1 — 选择服务器（ssh 连接方式）

```bash
"$RH/scripts/server-guesses.sh"   # candidate `ssh <target>` lines (config aliases / known_hosts / history)
```
**AskUserQuestion**："你的项目托管在哪台服务器上（如何 ssh 连接）？"
- 列出每个候选项（如 `ssh myserver`、`ssh dev@10.0.0.5`）+ 其他（自由输入，如 `ssh -p 2222 dev@server.example.com`）。
- 提取 `CONNECT` = 去掉开头 `ssh` 的参数（如 `myserver` 或 `-p 2222 dev@host`）。

## F-2 — 选择服务器上的项目目录

```bash
"$RH/scripts/preflight.sh" --direction forward --server '<CONNECT>'   # re-run now that we know the server
```
- `SERVER_REACHABLE=0` → 协助修复 ssh/密钥问题（用户可能只是被要求输入密码——提醒会话将非交互式），然后重新运行。不要结束本轮对话。
- `---PROJECTS---` 列表提供候选目录。**AskUserQuestion**："服务器上的项目目录是哪个？"——列出每个 `PROJECT` 路径 + 其他（自由输入的绝对路径）→ `REMOTE_PROJECT_DIR`。

## F-2.5 — 确认本地挂载点（必须）

**AskUserQuestion**"本机的哪个目录用于挂载项目并启动 Agent？"：
- "这里：`<cwd>`（当前目录）"——仅当目录为空（`PROJECT_DIR_EMPTY=1`）时提供；为空时预先选中。→ 传入 `--mountpoint '<cwd>'`。
- "自动创建 `~/remote-harness-mounts/<name>` 目录"——当前目录非空时预先选中。→ **省略** `--mountpoint`。
- 其他（另一个空的本地目录）→ 传入 `--mountpoint '<that dir>'`。

## F-3 — 生成本地命令 — 然后你的任务完成

使用 **F-2.5** 确定的 `<LOCAL_MP>`（以及是否传入 `--mountpoint`），以及 **F-2** 中用户确认的 `<REMOTE_PROJECT_DIR>`——均来自用户确认，不得猜测。

**完整打印**以下内容（简短，用 `\` 续行）：

```
"$HOME/.remote-harness/scripts/local-setup.sh" \
  --via '<CONNECT>' --remote-path '<REMOTE_PROJECT_DIR>' \
  [--mountpoint '<LOCAL_MP>'] --launch <LAUNCH> [--yolo]
```
- `<LAUNCH>` = 当前 Agent 的 CLI 名称（claude/codex/opencode）。
- `[--yolo]` 仅在用户要求跳过审批时添加。

告知用户：

> 在**新开的本地终端**中运行此命令（Agent 将接管该终端）。它将：
> 1. 确保到服务器的稳定 ssh 别名（若你提供的是原始参数，则写入 `<host>-dev` 别名）
> 2. 通过 sshfs 将服务器上的项目挂载到本地目录
> 3. 在该目录启动 Agent——构建/测试在服务器上执行（`ssh <alias> ...`），你的编辑实时生效
>
> 退出后，挂载将自动卸载。重新运行 `/remote-harness` 即可重新连接。

**你的本轮对话到此结束** — `local-setup.sh` 在本地侧自包含且具有交互性。

### 故障排查（正向模式）
- **提示输入密码**（sshfs/构建）→ 为服务器配置 ssh 密钥；配置后托管的 `<host>-dev` 别名将实现非交互式连接。在此之前会话会有密码提示。
- **`not-empty`** → 所选本地挂载点非空；脚本会提示选择其他目录（或通过 `--mountpoint <empty-dir>` 传入）。
- **macOS 上的 sshfs 缺少 macFUSE** → 挂载步骤会弹出 **no-kext** 安装提示（`brew install macos-fuse-t/homebrew-cask/fuse-t && brew install macos-fuse-t/homebrew-cask/sshfs-fuse-t`），安装后自动重试。FUSE-T **无需内核扩展，也无需降低系统安全性**，且保留了 sshfs 的同步写入特性（确保编辑在远程构建前已落盘）。避免使用 macFUSE（需要降低安全性）。
  - *若 FUSE-T 出现异常，备用方案：* `rclone`（`brew install rclone`，配置一个 sftp 远程端，然后执行 `rclone nfsmount remote:/path <mp> --vfs-cache-mode full --vfs-write-back 0`）——同样无需 kext，但写入是**异步**的，因此紧接着编辑后立即触发远程构建可能短暂看到旧文件。本技能的"本地编辑/服务器构建"工作流优先推荐 FUSE-T。
