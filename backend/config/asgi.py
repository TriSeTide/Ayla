"""
ASGI 入口 —— Channels 协议路由 + lifespan（内嵌 SSE 出站投影）。

Django 请求经 ProtocolTypeRouter 分流：
- http -> Django ASGI（API / 健康检查 / admin）
- websocket -> JWT 认证中间件 + 应用内 WS 路由（presence 等）
- lifespan -> 由外层包装器处理：startup 时启动内嵌 run_bridge（SSE 出站
  投影，apps/elysia_bridge/inline.py），shutdown 时优雅停止。
  Channels ProtocolTypeRouter 不处理 lifespan scope，需在 application 外层
  包一层按 scope type 分流。
"""
import logging
import os

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

from django.core.asgi import get_asgi_application  # noqa: E402

django_asgi_app = get_asgi_application()

from channels.auth import AuthMiddlewareStack  # noqa: E402
from channels.routing import ProtocolTypeRouter, URLRouter  # noqa: E402

from apps.accounts.routing import websocket_urlpatterns as accounts_ws  # noqa: E402
from apps.chat.routing import websocket_urlpatterns as chat_ws  # noqa: E402
from apps.voice.routing import websocket_urlpatterns as voice_ws  # noqa: E402

logger = logging.getLogger("asgi.lifespan")

application = ProtocolTypeRouter(
    {
        "http": django_asgi_app,
        "websocket": AuthMiddlewareStack(
            URLRouter(
                accounts_ws
                + chat_ws
                + voice_ws
                # 后续里程碑在此追加 livestream / tabletop 等 ws 路由
            )
        ),
    }
)


async def _lifespan_app(scope, receive, send) -> None:
    """处理 lifespan scope：startup 启动内嵌 bridge，shutdown 优雅停止。"""
    del scope
    bridge_state = None
    while True:
        message = await receive()
        if message["type"] == "lifespan.startup":
            try:
                from apps.elysia_bridge.inline import start_inline_bridge

                bridge_state = await start_inline_bridge()
            except Exception:  # noqa: BLE001 - 初始化失败不阻塞 server 启动
                logger.exception("lifespan startup: 内嵌 SSE 出站投影失败")
            await send({"type": "lifespan.startup.complete"})
        elif message["type"] == "lifespan.shutdown":
            try:
                from apps.elysia_bridge.inline import stop_inline_bridge

                await stop_inline_bridge(bridge_state)
            except Exception:  # noqa: BLE001
                logger.exception("lifespan shutdown: 内嵌 SSE 出站投影停止失败")
            await send({"type": "lifespan.shutdown.complete"})
            return
        else:  # pragma: no cover - 其它 lifespan 消息忽略
            continue


async def wrapped_application(scope, receive, send) -> None:
    """按 scope type 分流：lifespan 单独处理，其余交给 Channels 路由。"""
    if scope["type"] == "lifespan":
        await _lifespan_app(scope, receive, send)
    else:
        await application_(scope, receive, send)  # 原始 ProtocolTypeRouter


# 供 ASGI server（daphne/runserver/uvicorn）加载的入口
application_ = application  # 保留原引用便于测试/调试
application = wrapped_application
