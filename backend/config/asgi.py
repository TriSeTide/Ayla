"""
ASGI 入口 —— Channels 协议路由。

Django 请求经 ProtocolTypeRouter 分流：
- http -> Django ASGI（API / 健康检查 / admin）
- websocket -> JWT 认证中间件 + 应用内 WS 路由（presence 等）
"""
import os

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

from django.core.asgi import get_asgi_application  # noqa: E402

django_asgi_app = get_asgi_application()

from channels.auth import AuthMiddlewareStack  # noqa: E402
from channels.routing import ProtocolTypeRouter, URLRouter  # noqa: E402

from apps.accounts.routing import websocket_urlpatterns as accounts_ws  # noqa: E402
from apps.chat.routing import websocket_urlpatterns as chat_ws  # noqa: E402

application = ProtocolTypeRouter(
    {
        "http": django_asgi_app,
        "websocket": AuthMiddlewareStack(
            URLRouter(
                accounts_ws
                + chat_ws
                # 后续里程碑在此追加 livestream / tabletop 等 ws 路由
            )
        ),
    }
)
