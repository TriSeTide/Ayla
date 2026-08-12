"""Ayla 后端一键启动器：一并启动 runserver 与 run_bridge。

用法：
    python launcher.py                 # 默认 127.0.0.1:8100
    AYLA_HOST=0.0.0.0 AYLA_PORT=8000 python launcher.py

设计（AGENTS.md §7 生命周期与 owner）：
- 本启动器是 runserver 与 run_bridge 两个子进程的唯一 owner；
- 启动前检查目标端口是否已被占用：被占用则报告真实监听进程 PID（netstat 查询），
  不偷偷启动第二实例；
- Ctrl+C（SIGINT）→ 等待子进程自行优雅退出（runserver / run_bridge 都有
  SIGINT 处理），超时后 terminate/kill 兜底；任一子进程退出 → 整体退出；
- runserver 默认 `--noreload`：避免 reloader 分裂出的 worker 与本启动器
  生命周期解耦；代码改动后重启本启动器即可。

退出码：任一子进程的退出码；本启动器被信号中断时返回 130。
"""
from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = "8100"


def port_in_use(host: str, port: int) -> bool:
    """探测 host:port 是否已被监听（connect 成功即占用）。"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.6)
        try:
            sock.connect((host, port))
            return True
        except OSError:
            return False


def find_listener_pid(port: int) -> str:
    """尽力查询监听端口的进程 PID（Windows netstat / POSIX lsof，失败返回空串）。"""
    try:
        if sys.platform == "win32":
            out = subprocess.run(
                ["netstat", "-ano", "-p", "tcp"],
                capture_output=True,
                text=True,
                errors="replace",  # Windows netstat 输出 GBK，替换非法字节
                timeout=5,
            ).stdout
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 5 and parts[1].endswith(f":{port}") and parts[3] == "LISTENING":
                    return parts[4]
        else:
            out = subprocess.run(
                ["lsof", "-t", f"-iTCP:{port}", "-sTCP:LISTEN"],
                capture_output=True,
                text=True,
                errors="replace",
                timeout=5,
            ).stdout
            return out.strip().splitlines()[0] if out.strip() else ""
    except Exception:  # noqa: BLE001 - 查询失败不阻塞启动器
        return ""
    return ""


def _spawn(cmd: list[str]) -> subprocess.Popen:
    proc = subprocess.Popen(
        cmd,
        cwd=str(BACKEND_DIR),
        creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) if sys.platform == "win32" else 0,
    )
    print(f"[launcher] 已启动: {' '.join(cmd)} (pid={proc.pid})", flush=True)
    return proc


def main() -> int:
    host = os.environ.get("AYLA_HOST", DEFAULT_HOST)
    port = int(os.environ.get("AYLA_PORT", DEFAULT_PORT))
    python = sys.executable

    if port_in_use(host, port):
        pid = find_listener_pid(port)
        print(
            f"[launcher] 端口 {host}:{port} 已被占用"
            f"{f'（PID {pid}）' if pid else ''}，不启动第二实例。"
            f"请先停止现有 Ayla 后端，再运行本启动器。",
            file=sys.stderr,
            flush=True,
        )
        return 1

    runserver_cmd = [python, "manage.py", "runserver", "--noreload", f"{host}:{port}"]
    bridge_cmd = [python, "manage.py", "run_bridge"]

    procs: list[subprocess.Popen] = []
    interrupted = False
    try:
        procs.append(_spawn(runserver_cmd))
        procs.append(_spawn(bridge_cmd))
        print("[launcher] Ayla 后端已启动：Ctrl+C 一并退出", flush=True)

        while True:
            for proc in procs:
                rc = proc.poll()
                if rc is not None:
                    print(
                        f"[launcher] 子进程退出 rc={rc}，整体关闭（owner 语义）",
                        flush=True,
                    )
                    return rc
            time.sleep(1)
    except KeyboardInterrupt:
        interrupted = True
        print("[launcher] 收到 Ctrl+C，等待子进程优雅退出…", flush=True)
    finally:
        _shutdown(procs)
    return 130 if interrupted else 0


def _shutdown(procs: list[subprocess.Popen]) -> None:
    """等待子进程退出，超时后 terminate/kill 兜底（不重复终止已退出进程）。"""
    deadline = time.monotonic() + 8
    for proc in procs:
        if proc.poll() is None:
            try:
                proc.wait(timeout=max(0.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                pass
    for proc in procs:
        if proc.poll() is None:
            try:
                proc.terminate()
            except OSError:
                pass
    deadline = time.monotonic() + 5
    for proc in procs:
        if proc.poll() is None and time.monotonic() < deadline:
            try:
                proc.wait(timeout=max(0.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                pass
    for proc in procs:
        if proc.poll() is None:
            try:
                proc.kill()
            except OSError:
                pass
    print("[launcher] 全部子进程已退出", flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
