"""elysia_bridge WebSocket 路由（Ayla 通道，REQUIREMENTS.zh.md §6）。

DSH 主动拨入：`/ws/elysia-bridge/?token=<access_jwt>`。
由 `config/asgi.py` 追加在 accounts / chat / voice / live 的 ws 路由之后。
"""
from django.urls import path

from .consumers import AylaBridgeConsumer

websocket_urlpatterns = [
    path("ws/elysia-bridge/", AylaBridgeConsumer.as_asgi()),
]
