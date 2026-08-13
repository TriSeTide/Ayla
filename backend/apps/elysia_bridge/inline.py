"""内嵌 SSE 出站投影 —— 在 Ayla 后端进程内运行 run_bridge_loop。

两种启动入口：
1. **AppConfig.ready() 守护线程**（默认路径，`start_bridge_thread`）：
   Django 进程（runserver/daphne/uvicorn）在 django.setup() 时启动一个
   daemon 线程跑 run_bridge_loop；进程退出时线程随之终止（SSE 断连，
   Elysium 侧幂等 + bridge 重连保护兜底）。
2. **ASGI lifespan**（`start_inline_bridge`/`stop_inline_bridge`，备用）：
   供支持 lifespan 的 ASGI server（uvicorn）优雅管理；daphne 4.x 不支持
   lifespan，故默认走 ready() 线程路径。

单实例与生命周期（AGENTS.md §7 owner/并发）：
- **文件锁（runtime/elysia_bridge.lock）保证单实例**：runserver reload /
  多 worker 场景下只有一个进程持有锁并运行 bridge，其余跳过（warning）；
- 开关：`settings.ELYSIA_BRIDGE_INLINE`（默认 True，`.env` 可关）。关闭后
  等同旧方式：独立进程 `manage.py run_bridge`（命令保留）；
- 初始化失败（未配置 ELYSIA_BASE_URL / 无启用 profile / 无凭据）不阻塞
  server 启动：记 warning 并跳过。Elysium 未运行由 run_bridge_loop 的
  有界退避覆盖（不崩溃，等 Elysium 起来后自动连上）。
"""
from __future__ import annotations

import asyncio
import logging
import os
import sys
import threading
import time
from pathlib import Path
from typing import Any

from django.conf import settings

logger = logging.getLogger(__name__)

_LOCK_FILENAME = "elysia_bridge.lock"

# 线程级自动重启退避（秒）：run_bridge_loop 的断线重连覆盖 Elysium 未运行/
# 重启窗口；这里兜底"线程整体异常退出"（例如 Elysium 重启瞬间 ensure_session
# 的 httpx 连接错误击穿循环），按有界退避自动重启，不依赖手动重启 Ayla 后端。
_THREAD_RESTART_BASE = 5.0
_THREAD_RESTART_MAX = 60.0


# ---------- 判定与入口 ----------


def _is_server_process() -> bool:
    """当前进程是否为 Ayla 后端 server（runserver / daphne / uvicorn）。

    manage.py migrate/shell/test 等命令不启动 bridge；pytest 由
    settings_test 的 ELYSIA_BRIDGE_INLINE=False 另行拦截。
    """
    argv0 = (sys.argv[0] or "").lower()
    if argv0.endswith("manage.py"):
        return any(arg == "runserver" for arg in sys.argv[1:])
    basename = os.path.basename(argv0)
    return "daphne" in basename or "uvicorn" in basename


def _should_start_inline() -> bool:
    if not getattr(settings, "ELYSIA_BRIDGE_INLINE", True):
        return False
    if not getattr(settings, "ELYSIA_BASE_URL", "").rstrip("/"):
        return False
    return _is_server_process()


def start_bridge_thread() -> None:
    """AppConfig.ready() 入口：判定通过则启动 daemon 线程运行 bridge。"""
    if not _should_start_inline():
        return
    lock_fd = _acquire_lock()
    if lock_fd is None:
        logger.warning(
            "内嵌 SSE 出站投影跳过：已有实例持有锁（%s）", _lock_path()
        )
        return
    thread = threading.Thread(
        target=_bridge_thread_main,
        args=(lock_fd,),
        name="elysia-bridge-inline",
        daemon=True,
    )
    thread.start()
    logger.info(
        "内嵌 SSE 出站投影线程已启动（pid=%s, 单实例锁已持有）", os.getpid()
    )


def _bridge_thread_main(lock_fd: int) -> None:
    """daemon 线程体：运行 bridge，异常退出后按有界退避自动重启。

    - 单实例锁由本线程在生命周期内持有（进程退出时 fd 关闭自动释放）；
    - `_run_bridge_once` 每次重建 client/credentials/event loop；
    - run_bridge_loop 的断线重连负责"Elysium 未运行/重启窗口"的恢复；
      这里兜底"线程整体异常退出"，退出后 sleep 退避重启，避免依赖
      手动重启 Ayla 后端才能恢复爱莉双向通道。
    """
    restart_delay = _THREAD_RESTART_BASE
    while True:
        try:
            _run_bridge_once(lock_fd)
            # run_bridge_loop 正常返回（未来显式停止场景）也短暂退避重启
            logger.info(
                "内嵌 SSE 出站投影正常结束，%ss 后重启", restart_delay
            )
        except Exception:  # noqa: BLE001 - 线程异常不击穿 server，走自动重启
            logger.exception(
                "内嵌 SSE 出站投影异常退出，%ss 后自动重启", restart_delay
            )
        time.sleep(restart_delay)
        restart_delay = min(restart_delay * 2, _THREAD_RESTART_MAX)


def _run_bridge_once(lock_fd: int) -> None:
    """单轮 bridge 运行：查询 profile → 建 client/credentials/loop → run_bridge_loop。"""
    from apps.elysia_bridge.elysia_client import ElysiaClient
    from apps.elysia_bridge.models import ElysiaProfile
    from apps.elysia_bridge.services import (
        ElysiaCredentialManager,
        run_bridge_loop,
    )

    profile = (
        ElysiaProfile.objects.filter(enabled=True)
        .select_related("user")
        .first()
    )
    if profile is None:
        logger.warning("内嵌 SSE 出站投影跳过：未找到启用的爱莉 profile")
        raise RuntimeError("no enabled elysia profile")

    base_url = getattr(settings, "ELYSIA_BASE_URL", "").rstrip("/")
    client = ElysiaClient(base_url=base_url)
    credentials = ElysiaCredentialManager(
        client=client,
        secret_path=getattr(settings, "ELYSIA_CREDENTIAL_FILE", None),
    )
    stop_event = asyncio.Event()
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    logger.info(
        "内嵌 SSE 出站投影已启动：stream=%s → %s",
        profile.stream_id,
        base_url,
    )
    try:
        loop.run_until_complete(
            run_bridge_loop(
                profile=profile,
                client=client,
                credentials=credentials,
                stop_event=stop_event,
            )
        )
    finally:
        client.close()
        loop.close()


# ---------- 文件锁 ----------


def _lock_path() -> Path:
    runtime_dir = Path(settings.BASE_DIR) / "runtime"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    return runtime_dir / _LOCK_FILENAME


def _acquire_lock() -> int | None:
    """非阻塞获取 bridge 单实例文件锁；失败（已有实例）返回 None。

    Windows 用 msvcrt.locking（LK_NBLCK 非阻塞），POSIX 用 fcntl.flock
    （LOCK_EX|LOCK_NB）。统一锁定文件首字节区域，同一文件不同 fd 互斥。
    锁随 fd 关闭/进程退出自动释放。
    """
    path = _lock_path()
    try:
        fd = os.open(str(path), os.O_CREAT | os.O_RDWR)
        if os.fstat(fd).st_size == 0:
            os.write(fd, b"\0")
        os.lseek(fd, 0, os.SEEK_SET)
        if os.name == "nt":  # pragma: no cover - Windows
            import msvcrt

            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
        else:  # pragma: no cover - POSIX
            import fcntl

            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except OSError:
        try:
            os.close(fd)  # type: ignore[possibly-undefined]
        except (OSError, UnboundLocalError):
            pass
        return None


def _release_lock(fd: int | None) -> None:
    if fd is None:
        return
    try:
        if os.name == "nt":  # pragma: no cover - Windows
            import msvcrt

            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        else:  # pragma: no cover - POSIX
            import fcntl

            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
    except OSError:  # pragma: no cover - 释放失败不影响主流程
        pass


# ---------- ASGI lifespan 入口（备用，uvicorn 等支持 lifespan 的 server） ----------


async def start_inline_bridge() -> dict[str, Any] | None:
    """lifespan startup：启动内嵌 bridge 后台任务（备用入口）。

    返回状态 dict（task/stop_event/client/lock_fd），供 shutdown 停止；
    任何前置不满足返回 None。
    """
    if not _should_start_inline():
        return None
    lock_fd = _acquire_lock()
    if lock_fd is None:
        logger.warning(
            "内嵌 SSE 出站投影跳过：已有实例持有锁（%s）", _lock_path()
        )
        return None
    try:
        from channels.db import database_sync_to_async

        from apps.elysia_bridge.elysia_client import ElysiaClient
        from apps.elysia_bridge.models import ElysiaProfile
        from apps.elysia_bridge.services import (
            ElysiaCredentialManager,
            run_bridge_loop,
        )

        profile = await database_sync_to_async(
            lambda: ElysiaProfile.objects.filter(enabled=True)
            .select_related("user")
            .first()
        )()
        if profile is None:
            logger.warning("内嵌 SSE 出站投影跳过：未找到启用的爱莉 profile")
            _release_lock(lock_fd)
            return None

        base_url = getattr(settings, "ELYSIA_BASE_URL", "").rstrip("/")
        client = ElysiaClient(base_url=base_url)
        credentials = ElysiaCredentialManager(
            client=client,
            secret_path=getattr(settings, "ELYSIA_CREDENTIAL_FILE", None),
        )
        stop_event = asyncio.Event()

        async def _runner() -> None:
            try:
                await run_bridge_loop(
                    profile=profile,
                    client=client,
                    credentials=credentials,
                    stop_event=stop_event,
                )
            except Exception:  # noqa: BLE001 - 后台任务异常不击穿 server
                logger.exception("内嵌 SSE 出站投影异常退出")
            finally:
                client.close()

        task = asyncio.create_task(_runner(), name="elysia-bridge-inline")
        logger.info(
            "内嵌 SSE 出站投影已启动（lifespan）：stream=%s → %s",
            profile.stream_id,
            base_url,
        )
        return {
            "task": task,
            "stop_event": stop_event,
            "client": client,
            "lock_fd": lock_fd,
        }
    except Exception:  # noqa: BLE001 - 初始化失败不阻塞 server 启动
        logger.exception("内嵌 SSE 出站投影初始化失败")
        _release_lock(lock_fd)
        return None


async def stop_inline_bridge(state: dict[str, Any] | None) -> None:
    """lifespan shutdown：优雅停止内嵌 bridge（stop_event → 等待 → 释放锁）。"""
    if not state:
        return
    task = state.get("task")
    stop_event = state.get("stop_event")
    if isinstance(stop_event, asyncio.Event):
        stop_event.set()
    if task is not None:
        try:
            await asyncio.wait_for(asyncio.shield(task), timeout=6)
        except (asyncio.TimeoutError, asyncio.CancelledError):  # pragma: no cover
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass
    _release_lock(state.get("lock_fd"))
    logger.info("内嵌 SSE 出站投影已停止（lifespan）")
