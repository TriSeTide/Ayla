"""语音频道 WebSocket 路由。

两条通道分工：
  ws/voice/        状态/控制（订阅 voice.state 广播）—— VoiceConsumer
  ws/voice/audio/  媒体（二进制 Opus 帧转发）      —— VoiceAudioConsumer
"""
from django.urls import re_path

from . import audio_consumer, consumers

websocket_urlpatterns = [
    re_path(r"^ws/voice/$", consumers.VoiceConsumer.as_asgi()),
    re_path(r"^ws/voice/audio/$", audio_consumer.VoiceAudioConsumer.as_asgi()),
]
