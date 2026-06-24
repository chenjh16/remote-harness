#!/usr/bin/env bash
# remote-harness / simple-dispatch.sh - run ON THE LOCAL MACHINE.
#
# Internal local dispatcher for simple mode. simple-bootstrap.sh calls this with
# --mode reverse/forward, or omits --mode so the user chooses locally. It then
# hands off to the mode-specific local wizard.
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

cache_file() {
  printf '%s' "${RH_SIMPLE_MODE_CACHE:-$HOME/.remote-harness/simple-mode-cache.env}"
}

cache_get_mode() {
  _cache="$(cache_file)"
  [ -r "$_cache" ] || return 0
  sed -n 's/^LAST_MODE=//p' "$_cache" | tail -1
}

cache_save_mode() {
  _cache="$(cache_file)"
  case "$MODE" in reverse|forward) ;; *) return 0;; esac
  mkdir -p "$(dirname "$_cache")" 2>/dev/null || true
  _tmp="$(mktemp "${_cache}.XXXXXX" 2>/dev/null)" || return 0
  if [ -f "$_cache" ]; then
    grep -v '^LAST_MODE=' "$_cache" 2>/dev/null > "$_tmp" || true
  fi
  printf 'LAST_MODE=%s\n' "$MODE" >> "$_tmp"
  mv "$_tmp" "$_cache" 2>/dev/null && chmod 600 "$_cache" 2>/dev/null || true
}

normalize_mode() {
  _m="$(printf '%s' "${1:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$_m" in
    ""|1|r|R|reverse|Reverse|REV|远程开发本地|远程开发本地项目|远端开发本地|远端开发本地项目)
      printf 'reverse'; return 0;;
    2|f|F|forward|Forward|FWD|本地开发远程|本地开发远程项目|本地开发服务器项目|本地开发远端项目)
      printf 'forward'; return 0;;
    *) return 1;;
  esac
}

prompt_mode() {
  _default="${1:-reverse}"
  case "$_default" in reverse|forward) ;; *) _default=reverse;; esac
  while :; do
    if is_zh; then
      _prompt="$(printf '开发模式：1=远程开发本地项目(reverse)，2=本地开发远程项目(forward) [%s]: ' "$_default")"
    else
      _prompt="$(printf 'Development mode: 1=remote develops local project (reverse), 2=local develops server project (forward) [%s]: ' "$_default")"
    fi
    if [ -t 0 ] && [ -w /dev/tty ] 2>/dev/null; then printf '%s' "$_prompt" >/dev/tty; else printf '%s' "$_prompt" >&2; fi
    _answer=""
    if [ -t 0 ] && [ -r /dev/tty ] 2>/dev/null; then
      IFS= read -r _answer </dev/tty || _answer=""
    else
      IFS= read -r _answer || _answer=""
    fi
    [ -n "$_answer" ] || _answer="$_default"
    if MODE="$(normalize_mode "$_answer")"; then
      printf '%s' "$MODE"
      return 0
    fi
    if is_zh; then
      warn "请输入 1/reverse 或 2/forward。"
    else
      warn "Please enter 1/reverse or 2/forward."
    fi
  done
}

MODE="" SOURCE_VIA="" LAUNCH="codex" YOLO=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)       need_arg "$1" "${2-}"; MODE="$2"; shift 2;;
    --source-via) need_arg "$1" "${2-}"; SOURCE_VIA="$2"; shift 2;;
    --launch)     need_arg "$1" "${2-}"; LAUNCH="$2"; shift 2;;
    --yolo)       YOLO=1; shift;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
  esac
done
case "$LAUNCH" in
  claude|codex|opencode) ;;
  *) printf 'unsupported --launch %s (expected claude|codex|opencode)\n' "$LAUNCH" >&2; exit 2;;
esac

if [ -n "$MODE" ]; then
  MODE="$(normalize_mode "$MODE")" || { printf 'unsupported --mode %s\n' "$MODE" >&2; exit 2; }
else
  cached_mode="$(cache_get_mode)"
  if [ -n "$cached_mode" ] && ! [ -t 0 ]; then
    MODE="$(normalize_mode "$cached_mode")" || MODE=reverse
  else
    MODE="$(prompt_mode "$cached_mode")"
  fi
fi
cache_save_mode

case "$MODE" in
  forward)
    [ -x "$SCRIPT_DIR/simple-local-setup.sh" ] || { err "missing simple-local-setup.sh in $SCRIPT_DIR"; exit 2; }
    args=(--launch "$LAUNCH")
    [ "$YOLO" = 1 ] && args+=(--yolo)
    exec bash "$SCRIPT_DIR/simple-local-setup.sh" "${args[@]}"
    ;;
  reverse)
    [ -x "$SCRIPT_DIR/simple-laptop-setup.sh" ] || { err "missing simple-laptop-setup.sh in $SCRIPT_DIR"; exit 2; }
    args=(--launch "$LAUNCH")
    [ -n "$SOURCE_VIA" ] && args+=(--via "$SOURCE_VIA")
    [ "$YOLO" = 1 ] && args+=(--yolo)
    exec bash "$SCRIPT_DIR/simple-laptop-setup.sh" "${args[@]}"
    ;;
esac
