"""
语音频道 WebSocket Consumer —— 订阅频道组 `voice_chan_{id}` 收 `voice.state` 广播（M4-5 §8）。

复用 M4-2 Chat WS 的 JWT 认证与组订阅模式（`/ws/voice/?token=<jwt>`，解析见
`apps.accounts.consumers._jwt_user_from_scope`）；语音频道用独立组命名空间
`voice_chan_{id}`，避免与会话组 `chat_conv_{id}` 语义混淆/撞车。
"""
import logging

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer

from apps.accounts.consumers import _jwt_user_from_scope

from .services import _voice_group_name, mute_event, user_in_channel

logger = logging.getLogger(__name__)


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
        self.user = await database_sync_to_async(_jwt_user_from_scope)(self.scope)
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
        elif msg_type == "voice.mute":
            await self._handle_mute(content)
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
            # ⚠️ 统一按**字符串**记：客户端可能传 int 也可能传 str（Flutter 侧 channelId
            # 本来就是 String），若按原始类型存，`voice.mute` 的 int 比较会永远不匹配，
            # 表现为「静音帧被静默拒绝」。见 [_handle_mute] 的同款归一。
            self.subscribed.add(str(channel_id))
            await self.send_json(
                {
                    "type": "voice.subscribed",
                    "data": {"channel_id": str(channel_id)},
                }
            )

    async def _handle_mute(self, content):
        """客户端上报**自己**的静音态，服务端校验后广播给同频道订阅者。

        为什么要这一帧（2026-10-29 定位）：`voice.state` 原本只有
        joined/left/heartbeat；muted/unmuted 只由各端从 LiveKit 的
        TrackMuted/TrackUnmuted **本地合成**，服务端从不广播 ⇒ 换端登录、
        重进房间的成员永远看不到别人当前是否静音（跨端静音态不同步）。

        安全边界（严格）：
        - 只能上报**自己**（不接受 user_id 参数，恒用 self.user）；
        - 必须是该频道的**当前成员**，否则静默丢弃并回 error（不广播）；
        - channel_id 必须已订阅，避免向未订阅的组注入；
        - 只广播 muted/unmuted 两个值，不引入其它语义。
        """
        raw_cid = content.get("channel_id")
        muted = content.get("muted")
        if not isinstance(muted, bool) or raw_cid is None:
            await self.send_json({"type": "error", "detail": "invalid voice.mute payload"})
            return
        try:
            channel_id = int(raw_cid)
        except (TypeError, ValueError):
            await self.send_json({"type": "error", "detail": "invalid channel_id"})
            return
        if str(channel_id) not in getattr(self, "subscribed", set()):
            await self.send_json({"type": "error", "detail": "not subscribed"})
            return
        if not await _is_member(channel_id, self.user):
            # 非成员不得伪造他人的静音态
            await self.send_json({"type": "error", "detail": "not a member"})
            return
        await self.channel_layer.group_send(
            _voice_group_name(channel_id),
            mute_event(channel_id, self.user, muted),
        )

    # 频道组广播回调：voice.state（channels 把 event["type"] 里的 . 转成 _ 调用）
    async def voice_state(self, event):
        await self.send_json(event)

    # 频道组广播回调：voice.chat.message（房内聊天，直接转发完整 event）
    async def voice_chat_message(self, event):
        await self.send_json(event)
