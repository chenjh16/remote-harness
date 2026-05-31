#!/usr/bin/env python3
"""Drive the Codex TUI through the remote-harness skill with pexpect.

This is intentionally a live smoke test, not a hermetic unit test: it uses the
current Codex login/config, the installed remote-harness skill, and the current
machine's SSH/tunnel state. It verifies that Codex shows structured
request_user_input prompts and can accept keyboard answers.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import signal
import sys
import time
from pathlib import Path

try:
    import pexpect
except ImportError:  # checked after the explicit live-test opt-in gate
    pexpect = None


OSC_RE = re.compile(r"\x1b\](?:[^\x07\x1b]|\x1b(?!\\))*?(?:\x07|\x1b\\)")
CSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
ESC_RE = re.compile(r"\x1b[@-Z\\-_]")


def clean(text: str) -> str:
    text = OSC_RE.sub("", text)
    text = CSI_RE.sub("", text)
    text = ESC_RE.sub("", text)
    text = text.replace("\r", "\n")
    return re.sub(r"\n{3,}", "\n\n", text)


def tail(text: str, n: int = 6000) -> str:
    text = clean(text)
    return text[-n:]


def send(child: pexpect.spawn, keys: str, reason: str, delay: float = 0.15) -> None:
    print(f"[driver] {reason}: {keys!r}", flush=True)
    child.send(keys)
    time.sleep(delay)


def prompt_active(view: str) -> bool:
    return (
        "Question " in view
        or "Action Required" in view
        or "None of the above" in view
        or "to submit answer" in view
        or "enter to submit answer" in view
    )


def option_prompt_active(view: str) -> bool:
    return (
        prompt_active(view)
        or "Recommended" in view
        or "Recomended" in view
        or "推荐" in view
        or "Noneoftheabove" in view
        or "None of the above" in view
        or "Optionally" in view
        or "Optionaly" in view
    )


def active_prompt_text(view: str) -> str:
    starts = [view.rfind("Question "), view.rfind("Action Required")]
    start = max(starts)
    return view[start:] if start >= 0 else view


def send_option(child: pexpect.spawn, view: str, option: str, reason: str) -> None:
    # In Codex's structured input overlay, digit keys select and submit.
    # Chat fallback needs Enter.
    keys = option if option_prompt_active(view) else f"{option}\n"
    send(child, keys, reason)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--cwd",
        default=".",
        help="Codex working directory. Defaults to the current repo; pass a dedicated empty dir for reverse E2E.",
    )
    parser.add_argument(
        "--log",
        default=None,
        help="Raw transcript log path. Defaults to a unique /tmp path.",
    )
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument(
        "--prompt",
        default=(
            "$remote-harness yolo模式，中文。请完整执行 remote-harness 流程。"
            "YOLO 意图明确，不要为 yolo 额外提问；需要 AskUserQuestion 的确认项必须"
            "优先使用 request_user_input 结构化选择；最终只输出让我在本地运行的一条命令，"
            "不要实际运行这条最终命令。"
        ),
    )
    args = parser.parse_args()

    if os.environ.get("RUN_LIVE_CODEX_E2E") != "1":
        print("SKIP: set RUN_LIVE_CODEX_E2E=1 to start the live Codex TUI smoke test.")
        return 0
    if pexpect is None:
        print("pexpect is required for the live Codex TUI smoke test", file=sys.stderr)
        return 2
    if shutil.which("codex") is None:
        print("codex CLI not found in PATH", file=sys.stderr)
        return 2

    cwd = Path(args.cwd).expanduser()
    if not cwd.is_dir():
        print(f"cwd does not exist: {cwd}", file=sys.stderr)
        return 2

    if args.log:
        log_path = Path(args.log)
    else:
        stamp = time.strftime("%Y%m%d%H%M%S")
        log_path = Path(f"/tmp/remote-harness-codex-tui-e2e.{os.getpid()}.{stamp}.log")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log = log_path.open("w", encoding="utf-8", errors="replace")

    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")
    env.setdefault("COLORTERM", "truecolor")
    env.setdefault("COLUMNS", "140")
    env.setdefault("LINES", "40")

    cmd = [
        "codex",
        "--no-alt-screen",
        "--dangerously-bypass-approvals-and-sandbox",
        "-C",
        str(cwd),
        args.prompt,
    ]
    print(f"[driver] spawning: {' '.join(cmd)}", flush=True)
    child = pexpect.spawn(
        cmd[0],
        cmd[1:],
        cwd=str(cwd),
        env=env,
        encoding="utf-8",
        timeout=args.timeout,
        dimensions=(40, 140),
        preexec_fn=os.setsid,
    )
    child.logfile_read = log

    history = ""
    seen_structured_prompt = False
    sent_yolo_mode = False
    sent_direction = False
    sent_connect = False
    sent_mountpoint = False
    sent_project_dir = False
    final_command_seen = False
    last_debug = 0.0

    deadline = time.time() + args.timeout
    try:
        while time.time() < deadline:
            patterns = [
                "Question ",
                "Action Required",
                "None of the above",
                "to submit answer",
                "enter to submit answer",
                "执行模式",
                "YOLO",
                "Where does your code live",
                "代码相对于",
                "remote-harness 方向",
                "请选择 remote-harness 方向",
                "Reverse",
                "Forward",
                "How do you ssh",
                "ssh into this box",
                "本地电脑 SSH",
                "本地电脑上用哪条 SSH",
                "哪条 SSH 命令",
                "进入这台远端机器",
                "SSH 到这台",
                "怎么 ssh",
                "mountpoint",
                "挂载点",
                "挂载到",
                "Where on THIS box",
                "project directory",
                "项目目录",
                "本地项目",
                "笔记本项目",
                "代码目录",
                "代码库",
                "Which project",
                "哪个项目",
                "laptop-setup\\.sh",
                pexpect.TIMEOUT,
                pexpect.EOF,
            ]
            eof_idx = len(patterns) - 1
            idx = child.expect(patterns, timeout=10)
            before = child.before if isinstance(child.before, str) else ""
            after = child.after if isinstance(child.after, str) else ""
            if before or after:
                history = (history + before + after)[-120000:]
            view = tail(history, 20000)
            prompt_view = active_prompt_text(view)

            if prompt_active(prompt_view):
                seen_structured_prompt = True

            if idx == eof_idx:
                break

            if not sent_yolo_mode and option_prompt_active(prompt_view) and (
                "执行模式" in prompt_view
                or "YOLO 启用" in prompt_view
                or "YOLO mode" in prompt_view
                or "请选择本次 remote-harness 的执行模式" in prompt_view
            ):
                send_option(child, prompt_view, "1", "select YOLO mode")
                sent_yolo_mode = True
                history = ""
                continue

            if not sent_direction and option_prompt_active(prompt_view) and (
                "Where does your code live" in prompt_view
                or "代码相对于" in prompt_view
                or "remote-harness 方向" in prompt_view
                or "请选择 remote-harness 方向" in prompt_view
                or ("反向模式" in prompt_view and "正向模式" in prompt_view)
                or ("Reverse" in prompt_view and "Forward" in prompt_view)
            ):
                send_option(child, prompt_view, "1", "select Reverse")
                sent_direction = True
                history = ""
                continue

            if not sent_connect and prompt_active(prompt_view) and (
                "How do you ssh" in prompt_view
                or "ssh into this box" in prompt_view
                or "本地电脑 SSH" in prompt_view
                or "本地电脑上用哪条 SSH" in prompt_view
                or "哪个 SSH 命令" in prompt_view
                or "哪条 SSH 命令" in prompt_view
                or "SSH 命令连接" in prompt_view
                or "连接这台远端机器" in prompt_view
                or "进入这台远端机器" in prompt_view
                or "SSH 到这台" in prompt_view
                or "怎么 ssh" in prompt_view
                or sent_direction
            ):
                # Prefer the first generated ssh candidate. The historical flow
                # typed "ssh <alias>", but choosing a concrete candidate keeps
                # this smoke test deterministic without exercising free-form notes.
                send_option(child, prompt_view, "1", "select first ssh connection candidate")
                sent_connect = True
                history = ""
                continue

            if sent_connect and not sent_mountpoint and (
                "mountpoint" in prompt_view
                or "挂载点" in prompt_view
                or "挂载到" in prompt_view
                or "挂载" in prompt_view
                or "启动目录" in prompt_view
                or "空目录" in prompt_view
                or "Where on THIS box" in prompt_view
                or "remote-mountpoint" in prompt_view
                or "远端挂载" in prompt_view
                or option_prompt_active(prompt_view)
            ):
                send_option(child, prompt_view, "1", "select first/default mountpoint")
                sent_mountpoint = True
                history = ""
                continue

            if sent_connect and not sent_mountpoint and time.time() - last_debug > 10:
                compact = re.sub(r"\s+", " ", prompt_view)[-600:]
                print(f"[driver] waiting for mountpoint prompt; tail={compact!r}", flush=True)
                last_debug = time.time()

            if sent_connect and sent_mountpoint and not sent_project_dir and (
                "project directory" in prompt_view
                or "项目目录" in prompt_view
                or "项目" in prompt_view
                or "本地项目" in prompt_view
                or "笔记本项目" in prompt_view
                or "本地电脑" in prompt_view
                or "代码目录" in prompt_view
                or "代码库" in prompt_view
                or "要开发" in prompt_view
                or "/Users/" in prompt_view
                or "Which project" in prompt_view
                or "哪个项目" in prompt_view
                or option_prompt_active(prompt_view)
            ):
                send_option(child, prompt_view, "1", "select first/default project directory")
                sent_project_dir = True
                history = ""
                continue

            if sent_connect and sent_mountpoint and not sent_project_dir and time.time() - last_debug > 10:
                compact = re.sub(r"\s+", " ", prompt_view)[-600:]
                print(f"[driver] waiting for project prompt; tail={compact!r}", flush=True)
                last_debug = time.time()

            if (
                sent_connect
                and sent_mountpoint
                and sent_project_dir
                and option_prompt_active(prompt_view)
                and "submit answer" in prompt_view
            ):
                send(child, "\n", "submit completed structured answers")
                history = ""
                continue

            if (
                "Run this" in view
                or "在你的本地电脑终端运行" in view
                or "laptop-setup.sh" in view
            ) and "--launch codex" in view and "--yolo" in view:
                final_command_seen = True
                print("[driver] final command observed", flush=True)
                child.sendcontrol("c")
                break
    finally:
        if child.isalive():
            child.sendcontrol("c")
            try:
                child.expect(pexpect.EOF, timeout=10)
            except Exception:
                try:
                    os.killpg(os.getpgid(child.pid), signal.SIGTERM)
                    child.expect(pexpect.EOF, timeout=5)
                except Exception:
                    try:
                        os.killpg(os.getpgid(child.pid), signal.SIGKILL)
                    except Exception:
                        child.terminate(force=True)
        log.close()

    transcript = log_path.read_text(errors="replace")
    transcript_clean = clean(transcript)
    summary_path = log_path.with_suffix(".clean.txt")
    summary_path.write_text(transcript_clean)

    print(f"[driver] raw log: {log_path}", flush=True)
    print(f"[driver] clean log: {summary_path}", flush=True)
    print(f"[driver] structured_prompt={seen_structured_prompt}", flush=True)
    print(f"[driver] final_command={final_command_seen}", flush=True)

    if not seen_structured_prompt:
        print("request_user_input overlay was not observed", file=sys.stderr)
        return 1
    if not final_command_seen:
        print("final command was not observed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
