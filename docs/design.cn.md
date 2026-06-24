> 中文版。英文原版见 [design.md](design.md)（以英文版为准）。

# remote-harness — 设计

面向用户的文档见 [`../README.md`](../README.md)，运行时技能规格见 [`../SKILL.md`](../SKILL.md)，
开发指南见 [`../AGENTS.md`](../AGENTS.md)。

## 1. 问题

remote-harness 连接两台机器：

- **A**：编程 Agent 运行所在机器。
- **P**：项目和开发环境所在机器。

它用 sshfs 把 P 的项目挂载到 A，在会话中注入“项目命令必须在 P 上运行”的规则，然后在挂载目录启动选定 Agent。

## 2. 两个方向

- **Simple reverse**：A 是远端盒子，P 是用户笔记本。笔记本向盒子打开反向 SSH 隧道，盒子通过
  `rlocal` 回连笔记本。
- **Simple forward**：A 是本地机器，P 是 SSH 服务器。本地机器直接挂载服务器项目。
- **无法判断**：输出命令省略 `--mode`；`simple-dispatch.sh` 在本地询问并缓存模式。

所有情况的公开入口都是 `scripts/simple-bootstrap.sh`。命令总是在本地运行；脚本本身可以来自本地安装，
也可以从安装了 skill 的远端机器读取。

## 3. 分层

```text
SKILL.md
  -> simple-bootstrap.sh
      -> simple-dispatch.sh
          -> simple-laptop-setup.sh  -> laptop-setup.sh
          -> simple-local-setup.sh   -> local-setup.sh
              -> setup-tunnel/check-tunnel/mount-project/inject-rule
```

`_common.sh` 是被 source 的公共库，提供引用、提示、`parse_via` 和 `write_managed_alias`。辅助脚本在
stdout 输出可解析的 `KEY=VALUE`，在 stderr 输出人工提示。

## 4. SSH Config 模型

当前 simple 流程只使用**会话级 SSH config**：

| 流程 | Alias | Config 位置 | 作用 |
|---|---|---|---|
| reverse，笔记本 -> 盒子 | `<host>-remote-harness` | 本地 `~/.remote-harness/.sessions/.../ssh_config` | 携带 `RemoteForward <port> 127.0.0.1:22` |
| reverse，盒子 -> 笔记本 | `rlocal` | 远端 `~/.remote-harness/.sessions/.../ssh_config` | 通过盒子回环端口连回笔记本 |
| forward，本地 -> 服务器 | 已有 Host alias 或 `<host>-dev` | 本地 `~/.remote-harness/.sessions/.../ssh_config` | 给 sshfs 和服务器命令使用的短 alias，并隔离 SSH 运行期文件 |

simple 流程不得创建、编辑、备份、追加或清理本地或远端 `~/.ssh/config`、`known_hosts`、SSH key、
`config.rh-bak.*` 或 `known_hosts_<alias>`。临时 SSH config 和 `known_hosts` 都位于
`~/.remote-harness/.sessions/...`；生成的 config 关闭 OpenSSH multiplexing。

唯一有意的 `~/.ssh` 修改是 simple reverse 中笔记本侧的 `authorized_keys`：当远端提供
remote-harness 公钥时，`laptop-setup.sh` 会先检测本机是否已有匹配且有效的授权；若没有，才追加带
`remote-harness:reverse-auth:<tag>` 标签、并用 `from="127.0.0.1,::1"` 限制为回环来源的托管块。
`~/.remote-harness/.sessions/authorized-keys/...` 下的引用 token 用来避免一个会话退出时删除仍被
其他会话使用的授权。除此之外，`~/.ssh` 中已有历史文件都属于用户，除非用户明确要求，否则不修改。

启动后的 Agent 只看到短命令（`ssh rlocal ...` 或 `ssh <server-alias> ...`）。需要临时 config 时，
`inject-rule.sh` 会创建会话级 `bin/ssh` wrapper 并 prepend 到 `PATH`，因此注入规则不会暴露
`ssh -F <临时config>`。

## 5. 隐私边界

Agent 返回命令，不在聊天中收集具体 SSH target、本地路径、挂载路径或端口。这些由本地终端向导收集。
simple reverse 中，Agent 可以只基于服务器侧事实给出远端 SSH target 默认建议值。若使用
`SSH_CONNECTION`，只能使用第 3/4 字段（`server-ip`、`server-port`）；第 1/2 字段是本地客户端数据。

## 6. 规则注入

`inject-rule.sh` 是会话级且方向无关。它写入 `$RH_HOME/.sessions/<key>`，永不写入被挂载仓库。规则告诉 Agent：

- 在挂载目录中进行本地文件读取、写入、编辑和搜索是允许的；
- 项目命令必须通过 SSH 在 P 上运行；
- 会修改状态的 git 命令及其 hooks 也属于项目命令。

各 Agent 通道：

- Claude：`--append-system-prompt-file <rule>`。
- opencode：`OPENCODE_CONFIG=<session config>`。
- Codex：`-c developer_instructions=<rule>`；非 yolo 时还启用 workspace-write 网络访问，并只把相关
  `~/.remote-harness/.sessions/...` 目录加入 writable roots，让 SSH 把临时 `known_hosts` 和
  运行时文件写在那里，而不触碰 `~/.ssh`。

## 7. 不变量

1. `simple-bootstrap.sh` 是唯一公开 simple 入口。
2. 输出命令必须紧凑但可复制：少量短行，不输出超长单行 shell 块。
3. 调用中已明确 YOLO 时，传 `--yolo`，不得再二次询问。
4. simple 流程不扫描远端服务器发现项目；在本地询问路径，并把确认值缓存为默认值。
5. `laptop-setup.sh` 被 fetch 到无本地安装的笔记本时仍必须独立运行。
6. 所有拼进远程命令的值都用 `sq()` 做 shell 引用。
7. 会话清理会移除挂载、注入规则、临时 config，并在没有其它挂载需要时断开隧道。
