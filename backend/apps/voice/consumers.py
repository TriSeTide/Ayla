"""
语音频道 WebSocket Consumer —— 订阅频道组 `voice_chan_{id}` 收 `voice.state` 广播（M4-5 §8）。

复用 M4-2 Chat WS 的 JWT 认证与组订阅模式；语音频道用独立组命名空间 `voice_chan_{id}`，
避免与会话组 `chat_conv_{id}` 语义混淆/撞车。
"""
import logging

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer

from .services import _voice_group_name, user_in_channel

logger = logging.getLogger(__name__)


def _jwt_user_from_scope(scope):
    """从 scope 取已认证用户（复用 chat consumers 的同款 JWT 中间件）。"""
    return scope.get("user")


@database_sync_to_async
def _channel_exists(channel_id) -> bool:
    from .models import VoiceChannel

    try:
        VoiceChannel.objects.get(pk=channel_id)
        return True
    except (VoiceChannel.DoesNotExist, ValueError, TypeError):
        return False


@database_sync_to_async
def _is_member(channel_id, user) -> bool:
    from .models import VoiceChannel

    ch = VoiceChannel.objects.filter(pk=channel_id).first()
    if ch is None:
        return False
    return user_in_channel(ch, user)


class VoiceConsumer(AsyncJsonWebsocketConsumer):
    """WS 订阅语音频道，接收 voice.state 广播。"""

    async def connect(self):
        self.user = _jwt_user_from_scope(self.scope)
        if self.user is None or not self.user.is_authenticated:
            await self.close(code=4401)
            return
        self.subscribed = set()  # 已订阅的频道组
        await self.accept()

    async def disconnect(self, code):
        for channel_id in getattr(self, "subscribed", set()):
            await self.channel_layer.group_discard(
                _voice_group_name(channel_id), self.channel_name
            )

    async def receive_json(self, content, **kwargs):
        msg_type = content.get("type")
        if msg_type == "ping":
            await self.send_json({"type": "pong", "ts": content.get("ts")})
        elif msg_type == "subscribe":
            await self._handle_subscribe(content)
        else:
            await self.send_json({"type": "error", "detail": f"unknown type {msg_type}"})

    async def _handle_subscribe(self, content):
        channel_ids = content.get("channel_ids") or []
        for channel_id in channel_ids:
            if not await _channel_exists(channel_id):
                logger.info("subscribe ignored for missing channel %s", channel_id)
                continue
            if not await _is_member(channel_id, self.user):
                # 非频道成员：忽略（不 group_add），不能收到 voice.state
                logger.info("subscribe ignored for non-member vc %s", channel_id)
                continue
            group = _voice_group_name(channel_id)
            await self.channel_layer.group_add(group, self.channel_name)
            self.subscribed.add(channel_id)
            await self.send_json(
                {
                    "type": "voice.subscribed",
                    "data": {"channel_id": str(channel_id)},
                }
            )

    # 频道组广播回调：voice.state（channels 把 event["type"] 里的 . 转成 _ 调用）
    async def voice_state(self, event):
        await self.send_json(event)
