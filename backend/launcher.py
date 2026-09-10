"""Ayla 后端一键启动器：runserver + 内嵌 SSE 出站投影（run_bridge）。

用法：
    python launcher.py                 # 默认 127.0.0.1:8100
    AYLA_HOST=0.0.0.0 AYLA_PORT=8000 python launcher.py

设计（AGENTS.md §7 生命周期与 owner）：
- 本启动器是 runserver 进程的 owner；run_bridge（SSE 出站投影）已内嵌到
  ASGI lifespan（config/asgi.py → apps/elysia_bridge/inline.py），由
  `ELYSIA_BRIDGE_INLINE`（默认 True）控制，无需第二个进程；
- 启动前检查目标端口是否已被占用：被占用则报告真实监听进程 PID（netstat
  查询），不偷偷启动第二实例；
- **启动前自动应用数据库迁移**（`manage.py migrate --no-input`）：Django
  runserver 只警告不自动迁移（2026-09-10 事故：迁移未执行 + 新代码访问
  新字段 → 生产 500，见 docs/report/媒体链路500-迁移未执行-根因与修复）；
  迁移失败拒绝启动（显式失败，避免"新代码 + 旧 schema"静默上线）；
- Ctrl+C（SIGINT）→ runserver 自身优雅退出（内嵌 bridge 随 lifespan
  shutdown 停止）；
- runserver 默认 `--noreload`：避免 reloader 分裂出的 worker 与启动器
  生命周期解耦；代码改动后重启本启动器即可。

等价拆分调试：
    python manage.py runserver 127.0.0.1:8100 --noreload   # 含内嵌 bridge
    ELYSIA_BRIDGE_INLINE=False python manage.py runserver 127.0.0.1:8100
    python manage.py run_bridge                             # 独立 bridge

退出码：runserver 子进程的退出码；被信号中断时返回 130。
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


def _unapplied_migrations() -> list[str]:
    """轻量检查未应用迁移（不加载 Django，避免每次启动 2~16 秒 migrate 开销）。

    对比 django_migrations 表与磁盘迁移文件（apps/*/migrations/*.py），
    返回未应用的 "app.name" 列表。数据库不可达/表不存在时返回 ["<unknown>"]，
    表示需要跑完整 migrate（由 migrate 报真实错误并拒绝启动）。
    """
    import glob as _glob

    # 读 .env 数据库配置（与 config/settings.py 的 environ 读取保持一致）
    env: dict[str, str] = {}
    env_path = BACKEND_DIR / ".env"
    if env_path.exists():
        for line in env_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip().strip('"').strip("'")

    try:
        import pymysql

        conn = pymysql.connect(
            host=env.get("DB_HOST", "127.0.0.1"),
            port=int(env.get("DB_PORT", "3306")),
            user=env.get("DB_USER", "root"),
            password=env.get("DB_PASSWORD", ""),
            database=env.get("DB_NAME", "ayla"),
            connect_timeout=3,
        )
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT app, name FROM django_migrations")
                applied = {(app, name) for app, name in cur.fetchall()}
        finally:
            conn.close()
    except Exception:
        # 数据库不可达 / django_migrations 表不存在：交给完整 migrate 报真实错误
        return ["<unknown>"]

    on_disk: set[tuple[str, str]] = set()
    for path in _glob.glob(str(BACKEND_DIR / "apps" / "*" / "migrations" / "*.py")):
        filename = path.replace("\\", "/").rsplit("/", 1)[-1]
        if filename == "__init__.py":
            continue
        app = path.replace("\\", "/").split("/apps/")[-1].split("/migrations/")[0]
        on_disk.add((app, filename[:-3]))

    return [f"{app}.{name}" for app, name in sorted(on_disk - applied)]


def run_migrations(python: str) -> bool:
    """启动前自动应用数据库迁移（幂等：已应用的迁移自动跳过）。

    Django runserver 只打印未应用迁移警告、不自动执行（Django 5.2 源码
    BaseCommand.check_migrations 仅提示）。2026-09-10 事故证明警告会被忽略：
    迁移 0004 未执行 + 新代码访问新字段 → 生产 500。因此启动器显式执行
    `migrate --no-input`，失败拒绝启动（显式失败，不静默上线旧 schema）。

    性能：先用轻量检查（pymysql 对比 django_migrations 表与磁盘迁移文件，
    不加载 Django，<1s）判断是否有未应用迁移；无则跳过完整 migrate
    （完整 migrate 冷启动约 16s，不能每次启动都付）。
    """
    pending = _unapplied_migrations()
    if not pending:
        print("[launcher] 数据库迁移已是最新，跳过", flush=True)
        return True
    print(f"[launcher] 检测到未应用迁移: {', '.join(pending)}", flush=True)
    cmd = [python, "manage.py", "migrate", "--no-input"]
    print(f"[launcher] 应用数据库迁移: {' '.join(cmd)}", flush=True)
    try:
        proc = subprocess.run(cmd, cwd=str(BACKEND_DIR))
    except KeyboardInterrupt:
        print("[launcher] 迁移被中断，不启动", file=sys.stderr, flush=True)
        return False
    if proc.returncode != 0:
        print(
            f"[launcher] 数据库迁移失败（退出码 {proc.returncode}），拒绝启动。"
            "请修复迁移问题后重试。",
            file=sys.stderr,
            flush=True,
        )
        return False
    return True


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

    if not run_migrations(python):
        return 1

    runserver_cmd = [python, "manage.py", "runserver", "--noreload", f"{host}:{port}"]
    print(f"[launcher] 启动: {' '.join(runserver_cmd)}", flush=True)
    try:
        proc = subprocess.run(runserver_cmd, cwd=str(BACKEND_DIR))
        return int(proc.returncode)
    except KeyboardInterrupt:
        print("[launcher] 收到 Ctrl+C，等待 runserver 优雅退出…", flush=True)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
