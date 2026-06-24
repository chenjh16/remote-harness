# Simple Forward 流程方案

## 结论

可行。现有 forward 流程已经能把 SSH 服务器上的项目挂载到本地，注入“项目命令在服务器执行”的规则，
并在本地挂载目录中启动 Agent。新的 simple 层增加一个本地终端向导，让 skill 只返回一条短命令，而不是让
Agent 在聊天中收集服务器、路径和挂载点细节。

该模式面向：Codex/Agent 运行在本地；项目文件和开发环境位于可直接 SSH 访问的服务器。

"本地开发远程项目"、"本地开发服务器项目" 这类简短说法应选择该模式。"远程开发本地" 应选择
simple reverse。若请求模糊，则输出不带 `--mode` 的 `simple-bootstrap.sh`；它会移交给
`simple-dispatch.sh` 在本地选择，默认 reverse，并缓存模式选择。

## 边界

- 本地文件工具可以在映射目录中读取、写入、编辑和搜索文件。
- 项目命令必须通过 SSH 在服务器执行：构建、运行、测试、安装依赖、格式化、lint、language server、
  迁移、会修改状态的 git 命令，以及其他工具链/运行时工作。
- 本地向导收集服务器 SSH target、服务器项目目录、可选本地挂载点和启动偏好。
- simple 路径不扫描服务器来发现项目目录。缓存值只能作为提示默认值。
- 调用中明确要求 YOLO 时即为最终选择；向导不会再询问 YOLO。
- setup 始终在本地 `~/.remote-harness/.sessions/...` 下使用会话级 ssh config。Host alias 会通过该
  config 使用；原始 SSH 参数会得到会话级 `<host>-dev` alias。它不会在本地 `~/.ssh` 下创建或修改任何内容；
  临时 `known_hosts` 也留在 `~/.remote-harness/.sessions/...`，且生成的 config 会关闭 OpenSSH multiplexing。
- 默认本地挂载点是 `~/.remote-harness/mounts/<project>`；用户明确输入的挂载点可以使用。

## 用户命令形态

中文 Codex 场景下，skill 输出：

```bash
RH_LANG=zh bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  --mode forward --launch codex
```

只有当用户明确要求 YOLO/免审批/无审核模式时，才追加 `--yolo`。如果脚本来源在远端而非本地安装，
使用 `SKILL.md` 中的 fetch 形式；source SSH target 只用于加载 remote-harness 脚本，forward 向导会另外询问项目服务器 target。

## 流程

1. Agent 输出带 `--mode forward` 的 simple 命令。
2. `simple-bootstrap.sh` 移交给 `simple-dispatch.sh --mode forward`。
3. `simple-local-setup.sh` 在本地提示服务器 SSH target、服务器项目路径、可选本地挂载点，以及未显式指定时的 YOLO 偏好。
4. 它把确认过的默认值保存到 `~/.remote-harness/simple-forward-cache.env`。
5. 它调用 `local-setup.sh`。
6. `local-setup.sh` 为服务器 target 创建会话级 SSH config；若用户提供原始 SSH 参数，还会创建短 alias。
7. `mount-project.sh` 将 `<server-alias>:<server-project>` 通过 sshfs 挂载到本地挂载点。
8. `inject-rule.sh` 注入会话级规则，要求启动后的 Agent 把项目命令放到服务器执行。
9. 选定的本地 Agent 在挂载目录中启动。
10. Agent 退出后，脚本自动卸载 sshfs、删除会话规则、删除临时 ssh config，并在默认挂载点目录为空时清理它。

## 前置条件

- 本地已安装 remote-harness，默认在 `~/.remote-harness`，或者本地 `RH_HOME` 指向安装目录。
- 本地机器可以 SSH 登录服务器。
- 本地有 `sshfs`；缺失时 `mount-project.sh` 会给出对应系统的安装命令。
- 选定的 Agent CLI 已安装在本地。

## 失败与恢复

- SSH target 填错：重新运行命令并输入新的 target。
- 服务器项目路径填错：挂载失败；重新运行并输入正确路径。
- 本地挂载点非空：`local-setup.sh` 会提示换一个空目录。
- 未配置 SSH key：会话可能提示输入密码。配置 key 后 sshfs 和服务器命令会更顺滑。

## 已实现文件

- `scripts/simple-local-setup.sh`
- `scripts/simple-bootstrap.sh`
- `scripts/simple-dispatch.sh`
- `scripts/local-setup.sh`
- `scripts/mount-project.sh`
- `scripts/inject-rule.sh`
- `SKILL.md` / `SKILL.cn.md`
