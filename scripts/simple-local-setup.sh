#!/usr/bin/env bash
# remote-harness / simple-local-setup.sh - run ON THE LOCAL MACHINE.
#
# A local wizard for the forward flow: the coding agent runs locally, while the
# project and toolchain live on an SSH-reachable server. This collects concrete
# values in the user's terminal, then delegates to local-setup.sh.
set -uo pipefail
set -f

need_arg() {
  if [ -z "${2+x}" ] || [ -z "$2" ]; then
    printf 'missing value for %s\n' "$1" >&2
    exit 2
  fi
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RH_COMMON="${RH_COMMON:-$SCRIPT_DIR/_common.sh}"
if [ -f "$RH_COMMON" ]; then
  # shellcheck source=./_common.sh
  . "$RH_COMMON"
else
  printf 'error: missing _common.sh next to %s\n' "$0" >&2
  exit 2
fi

LANG_MODE="${RH_LANG:-en}"
is_zh() {
  case "$LANG_MODE" in zh|zh_*|zh-*|cn|CN|中文) return 0;; *) return 1;; esac
}

prompt_line() {
  _label="$1"
  _default="${2:-}"
  _required="${3:-0}"
  _answer=""
  while :; do
    if [ -n "$_default" ]; then
      printf '%s [%s]: ' "$_label" "$_default" >/dev/tty
    else
      printf '%s: ' "$_label" >/dev/tty
    fi
    if [ -r /dev/tty ]; then
      IFS= read -r _answer </dev/tty || _answer=""
    else
      IFS= read -r _answer || _answer=""
    fi
    [ -n "$_answer" ] || _answer="$_default"
    if [ "$_required" != 1 ] || [ -n "$_answer" ]; then
      printf '%s' "$_answer"
      return 0
    fi
    if is_zh; then warn "该值必填。"; else warn "This value is required."; fi
  done
}

prompt_yes_no() {
  _label="$1"
  _default="${2:-n}"
  if [ "$ASSUME_YES" = 1 ]; then
    [ "$_default" = y ] || [ "$_default" = Y ]
    return $?
  fi
  while :; do
    case "$_default" in y|Y) _suffix="[Y/n]";; *) _suffix="[y/N]";; esac
    printf '%s %s ' "$_label" "$_suffix" >/dev/tty
    _answer=""
    if [ -r /dev/tty ]; then
      IFS= read -r _answer </dev/tty || _answer=""
    else
      IFS= read -r _answer || _answer=""
    fi
    [ -n "$_answer" ] || _answer="$_default"
    case "$_answer" in
      y|Y|yes|YES|Yes|是|好) return 0;;
      n|N|no|NO|No|否|不) return 1;;
      *) if is_zh; then warn "请输入 y 或 n。"; else warn "Please answer y or n."; fi;;
    esac
  done
}

trim_via() {
  _v="$1"
  _v="$(printf '%s' "$_v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$_v" in
    ssh[[:space:]]*) _v="${_v#ssh }"; _v="$(printf '%s' "$_v" | sed 's/^[[:space:]]*//')";;
  esac
  printf '%s' "$_v"
}

expand_local_dir() {
  _v="$1"
  case "$_v" in
    "~") _v="$HOME";;
    "~/"*) _v="$HOME/${_v#~/}";;
  esac
  printf '%s' "${_v%/}"
}

cache_file() {
  printf '%s' "${RH_SIMPLE_FORWARD_CACHE:-$HOME/.remote-harness/simple-forward-cache.env}"
}

cache_get() {
  _key="$1"
  _cache="$(cache_file)"
  [ -r "$_cache" ] || return 0
  sed -n "s/^${_key}=//p" "$_cache" | tail -1
}

cache_save() {
  _cache="$(cache_file)"
  mkdir -p "$(dirname "$_cache")" 2>/dev/null || true
  _tmp="$(mktemp "${_cache}.XXXXXX" 2>/dev/null)" || return 0
  if [ -f "$_cache" ]; then
    grep -v -E '^(LAST_VIA|LAST_REMOTE_PROJECT_DIR|LAST_MOUNTPOINT|LAST_LAUNCH|LAST_YOLO)=' "$_cache" 2>/dev/null > "$_tmp" || true
  fi
  for _kv in \
    "LAST_VIA=$VIA" \
    "LAST_REMOTE_PROJECT_DIR=$RPATH" \
    "LAST_MOUNTPOINT=$MP" \
    "LAST_LAUNCH=$LAUNCH" \
    "LAST_YOLO=$YOLO"; do
    case "$_kv" in *'
'*) continue;; esac
    printf '%s\n' "$_kv" >> "$_tmp"
  done
  mv "$_tmp" "$_cache" 2>/dev/null && chmod 600 "$_cache" 2>/dev/null || true
}

auto_mountpoint() {
  _name="$(basename "${RPATH:-project}")"
  [ -n "$_name" ] && [ "$_name" != "/" ] || _name="project"
  printf '%s/.remote-harness/mounts/%s' "$HOME" "$_name"
}

VIA="" RPATH="" MP="" LAUNCH="codex" YOLO=0 YOLO_REQUESTED=0 ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --via)         need_arg "$1" "${2-}"; VIA="$2"; shift 2;;
    --remote-path) need_arg "$1" "${2-}"; RPATH="$2"; shift 2;;
    --mountpoint)  need_arg "$1" "${2-}"; MP="$2"; shift 2;;
    --launch)      need_arg "$1" "${2-}"; LAUNCH="$2"; shift 2;;
    --yolo)        YOLO=1; YOLO_REQUESTED=1; shift;;
    --yes|-y)      ASSUME_YES=1; shift;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
  esac
done
case "$LAUNCH" in
  claude|codex|opencode) ;;
  *) printf 'unsupported --launch %s (expected claude|codex|opencode)\n' "$LAUNCH" >&2; exit 2;;
esac

if is_zh; then
  hdr "Simple 正向远程开发设置"
  say "这个向导只在本地运行。项目会从服务器映射到本地，命令通过 SSH 在服务器执行。"
else
  hdr "Simple forward remote development setup"
  say "This wizard runs locally. Files are mounted here; commands run on the server over SSH."
fi
sep

if [ -z "$VIA" ]; then
  cached_via="$(cache_get LAST_VIA)"
  if is_zh; then
    VIA="$(prompt_line '服务器 SSH 目标/参数（不要带开头的 ssh；推荐 Host 别名）' "$cached_via" 1)"
  else
    VIA="$(prompt_line 'Server SSH target/args (omit leading ssh; Host alias is best)' "$cached_via" 1)"
  fi
fi
VIA="$(trim_via "$VIA")"
[ -n "$VIA" ] || { if is_zh; then err "未提供服务器 SSH 目标/参数。"; else err "No server SSH target/args provided."; fi; exit 2; }

parse_via "$VIA"
[ -z "${V_UNSUPPORTED_SSH_OPTIONS:-}" ] || {
  if is_zh; then
    err "不支持这些原始 ssh 选项：${V_UNSUPPORTED_SSH_OPTIONS}"
    say "请把复杂 SSH 选项放进 ~/.ssh/config 的 Host 别名里，然后重新运行并输入该别名。"
  else
    err "Unsupported raw ssh option(s):${V_UNSUPPORTED_SSH_OPTIONS}"
    say "Put complex SSH options in ~/.ssh/config as a Host alias, then rerun and enter that alias."
  fi
  exit 2
}
[ -n "$V_HOST" ] || { if is_zh; then err "无法从 SSH 目标中解析 host。"; else err "Could not parse a host from the SSH target."; fi; exit 2; }
[ -z "$V_HOST" ] || safe_ssh_token "$V_HOST" || { if is_zh; then err "SSH host token 不安全：$V_HOST"; else err "Unsafe SSH host token: $V_HOST"; fi; exit 2; }
[ -z "${V_USER:-}" ] || safe_ssh_token "$V_USER" || { if is_zh; then err "SSH user token 不安全：$V_USER"; else err "Unsafe SSH user token: $V_USER"; fi; exit 2; }

if [ -z "$RPATH" ]; then
  cached_rpath="$(cache_get LAST_REMOTE_PROJECT_DIR)"
  if is_zh; then
    RPATH="$(prompt_line '服务器项目目录（绝对路径或 ~/path）' "$cached_rpath" 1)"
  else
    RPATH="$(prompt_line 'Server project directory (absolute path or ~/path)' "$cached_rpath" 1)"
  fi
fi
RPATH="${RPATH%/}"
[ -n "$RPATH" ] || { if is_zh; then err "未提供服务器项目目录。"; else err "No server project directory provided."; fi; exit 2; }

if [ -z "$MP" ]; then
  cached_mp="$(cache_get LAST_MOUNTPOINT)"
  if [ -n "$cached_mp" ]; then
    if is_zh; then
      MP="$(prompt_line '本地挂载点（auto = ~/.remote-harness/mounts/<project>）' "$cached_mp" 0)"
    else
      MP="$(prompt_line 'Local mountpoint (auto = ~/.remote-harness/mounts/<project>)' "$cached_mp" 0)"
    fi
  else
    if is_zh; then
      MP="$(prompt_line '本地挂载点（留空 = ~/.remote-harness/mounts/<project>）' '' 0)"
    else
      MP="$(prompt_line 'Local mountpoint (blank = ~/.remote-harness/mounts/<project>)' '' 0)"
    fi
  fi
fi
MP="${MP%/}"
case "$MP" in auto|AUTO|-) MP="";; esac
[ -n "$MP" ] && MP="$(expand_local_dir "$MP")"

if [ "$YOLO_REQUESTED" = 1 ]; then
  YOLO=1
else
  cached_yolo="$(cache_get LAST_YOLO)"
  if [ "$cached_yolo" = 0 ]; then default_yolo=n; else default_yolo=y; fi
  if is_zh; then
    if prompt_yes_no "启动 ${LAUNCH} 时开启 YOLO/免审批模式？" "$default_yolo"; then YOLO=1; else YOLO=0; fi
  else
    if prompt_yes_no "Launch ${LAUNCH} with YOLO/bypass approvals?" "$default_yolo"; then YOLO=1; else YOLO=0; fi
  fi
fi

if is_zh; then
  hdr "执行计划"
  say "服务器：         ${VIA}"
  say "服务器项目：     ${RPATH}"
else
  hdr "Plan"
  say "Server:           ${VIA}"
  say "Server project:   ${RPATH}"
fi
if [ -n "$MP" ]; then
  if is_zh; then say "本地挂载点：     ${MP}"; else say "Local mountpoint: ${MP}"; fi
else
  if is_zh; then say "本地挂载点：     $(auto_mountpoint)"; else say "Local mountpoint: $(auto_mountpoint)"; fi
fi
if [ "$YOLO" = 1 ]; then
  if is_zh; then say "启动命令：       ${LAUNCH} --yolo"; else say "Launch:           ${LAUNCH} --yolo"; fi
else
  if is_zh; then say "启动命令：       ${LAUNCH}"; else say "Launch:           ${LAUNCH}"; fi
fi
if is_zh; then
  say "文件读写/编辑/搜索会在本地挂载目录中进行；构建、运行、测试等命令会通过 SSH 在服务器执行。"
  prompt_yes_no "继续执行这个设置？" y
else
  say "File reads/writes/edits/searches happen in the local mount; build/run/test commands run on the server via SSH."
  prompt_yes_no "Continue with this setup?" y
fi
if [ "$?" -ne 0 ]; then
  if is_zh; then err "已取消。"; else err "Aborted."; fi
  exit 1
fi
cache_save

cmd=(bash "$SCRIPT_DIR/local-setup.sh"
  --via "$VIA"
  --remote-path "$RPATH"
  --launch "$LAUNCH")
[ -n "$MP" ] && cmd+=(--mountpoint "$MP")
[ "$YOLO" = 1 ] && cmd+=(--yolo)

sep
if is_zh; then
  say "交给 local-setup.sh 继续处理 sshfs 挂载、规则注入和启动。"
else
  say "Handing off to local-setup.sh for sshfs mount, rule injection, and launch."
fi
exec "${cmd[@]}"
