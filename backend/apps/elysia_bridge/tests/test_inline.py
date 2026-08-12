"""内嵌 SSE 出站投影契约测试。

覆盖：
- 文件锁互斥：同一文件第二个 fd 拿不到锁；释放后可再获取；
- `_should_start_inline`：开关/ELYSIA_BASE_URL/server 进程判定；
- `ELYSIA_BRIDGE_INLINE=False`（settings_test 默认）时 start_inline_bridge 返回 None；
- asgi lifespan 协议：startup → 启动（本环境跳过）→ complete；shutdown → complete。
"""
import pytest

from apps.elysia_bridge import inline


def test_bridge_lock_is_exclusive_and_releasable(monkeypatch, tmp_path):
    lock_file = tmp_path / "elysia_bridge.lock"
    monkeypatch.setattr(inline, "_lock_path", lambda: lock_file)

    fd1 = inline._acquire_lock()
    assert fd1 is not None, "首个实例应拿到锁"
    try:
        fd2 = inline._acquire_lock()
        assert fd2 is None, "同一文件第二个实例不应拿到锁（互斥）"
    finally:
        inline._release_lock(fd1)

    fd3 = inline._acquire_lock()
    assert fd3 is not None, "释放后应可再获取锁"
    inline._release_lock(fd3)


def test_should_start_inline_disabled_by_default(settings):
    # settings_test：ELYSIA_BRIDGE_INLINE=False 且 ELYSIA_BASE_URL 为空
    assert inline._should_start_inline() is False


def test_should_start_inline_requires_server_process(settings, monkeypatch):
    settings.ELYSIA_BRIDGE_INLINE = True
    settings.ELYSIA_BASE_URL = "http://127.0.0.1:8000"

    # manage.py shell / migrate 等命令不启动
    monkeypatch.setattr("sys.argv", ["manage.py", "migrate"])
    assert inline._should_start_inline() is False

    # manage.py runserver 启动
    monkeypatch.setattr("sys.argv", ["manage.py", "runserver", "127.0.0.1:8100"])
    assert inline._should_start_inline() is True

    # daphne 生产入口启动
    monkeypatch.setattr("sys.argv", ["daphne", "config.asgi:application"])
    assert inline._should_start_inline() is True

    # 开关关闭则即使 server 进程也不启动
    settings.ELYSIA_BRIDGE_INLINE = False
    assert inline._should_start_inline() is False


def test_start_inline_bridge_disabled_returns_none(settings):
    assert settings.ELYSIA_BRIDGE_INLINE is False  # settings_test 默认关闭
    import asyncio

    state = asyncio.run(inline.start_inline_bridge())
    assert state is None


@pytest.mark.asyncio
async def test_lifespan_startup_shutdown_roundtrip():
    from config.asgi import _lifespan_app

    received = [{"type": "lifespan.startup"}, {"type": "lifespan.shutdown"}]
    sent: list[dict] = []

    async def receive():
        return received.pop(0)

    async def send(message):
        sent.append(message)

    await _lifespan_app({}, receive, send)
    assert sent == [
        {"type": "lifespan.startup.complete"},
        {"type": "lifespan.shutdown.complete"},
    ]

