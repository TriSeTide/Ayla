"""语音频道 WebSocket 路由。

  ws/voice/   状态/控制（订阅 voice.state 广播）—— VoiceConsumer

媒体走 LiveKit（单 UDP 端口经 frp 隧道），不再占用 WS。
`ws/voice/audio/` 中继通道已于 2026-10-28 删除。
"""
from django.urls import re_path

from . import consumers

websocket_urlpatterns = [
    re_path(r"^ws/voice/$", consumers.VoiceConsumer.as_asgi()),
]
