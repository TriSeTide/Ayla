"""直播弹幕 WebSocket 路由（M4-6 §5.2）。"""
from django.urls import re_path

from . import consumers

websocket_urlpatterns = [
    re_path(
        r"^ws/live/(?P<channel_id>\d+)/$", consumers.DanmakuConsumer.as_asgi()
    ),
]
