"""语音音频 WebSocket Consumer —— 房间音频总线（方案 a：纯转发）。

与 `consumers.VoiceConsumer` 的分工
-----------------------------------
- `VoiceConsumer`（`ws/voice/`）：**状态/控制**通道，订阅 `voice.state` 广播（谁进出、谁在说）
- `VoiceAudioConsumer`（`ws/voice/audio/`）：**媒体**通道，只跑二进制 Opus 帧
两者独立，组命名空间也不同（`voice_chan_{id}` vs `voice_audio_{id}`），互不干扰。

连接方式
--------
    wss://<host>/ws/voice/audio/?token=<jwt>&channel=<channel_id>

认证与成员校验都复用现有实现（`_jwt_user_from_scope` / `user_in_channel`），
不新造轮子，保证与 `VoiceConsumer` 同一套权限语义。

音频帧格式（与 audio_relay.py 的协议说明一致）
----------------------------------------------
C→S binary : 一个 20ms Opus 包（客户端仅在 speaking 时发送）
S→C binary : [1 字节 slot][Opus 包]
"""
import logging
from urllib.parse import parse_qs

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer

from apps.accounts.consumers import _jwt_user_from_scope

from . import audio_relay
from .services import user_in_channel

logger = logging.getLogger(__name__)


def _audio_group_name(channel_id) -> str:
    """音频组命名空间（与状态广播组 voice_chan_{id} 严格区分）。"""
    return f"voice_audio_{channel_id}"


@database_sync_to_async
def _resolve_membership(channel_id, user) -> bool:
    from .models import VoiceChannel

    ch = VoiceChannel.objects.filter(pk=channel_id).first()
    if ch is None:
        return False
    return user_in_channel(ch, user)


class VoiceAudioConsumer(AsyncJsonWebsocketConsumer):
    """房间音频中继。收到二进制帧只做裁决 + 前缀 slot 后转发，不解码。

    基类必须是 AsyncJsonWebsocketConsumer（而非 AsyncWebsocketConsumer）：
    `send_json` 只定义在前者上，用后者调用会抛 AttributeError，
    daphne 在 accept 之后捕获异常 → 客户端收到 close 1011、且看不到任何业务帧。
    它的 receive_json 分支不适用于本通道，因此下面重写 receive 同时接二进制与文本。
    """

    async def connect(self):
        # 失败路径要留痕：connect 里提前 return 前必须先给 self.xxx 兜底默认值，
        # 否则 channels 仍会调用 disconnect，getattr 守卫能避免 AttributeError。
        self.user = None
        self.channel_id = None
        self.slot = None
        self.room_group = None

        self.user = await database_sync_to_async(_jwt_user_from_scope)(self.scope)
        if self.user is None or not self.user.is_authenticated:
            await self.close(code=4401)
            return

        params = parse_qs(self.scope.get("query_string", b"").decode())
        raw_id = (params.get("channel") or [""])[0]
        try:
            channel_id = int(raw_id)
        except (TypeError, ValueError):
            await self.close(code=4400)
            return

        if not await _resolve_membership(channel_id, self.user):
            await self.close(code=4403)
            return

        self.channel_id = channel_id
        self.room_group = _audio_group_name(channel_id)

        await self.channel_layer.group_add(self.room_group, self.channel_name)
        await self.accept()

        member, roster_before = await audio_relay.join(
            channel_id, self.channel_name, getattr(self.user, "username", "") or str(self.user.pk)
        )
        self.slot = member.slot

        # 先把自己已加入的名单发给本人（含 slot ↔ identity 映射，前端据此显示"谁在说话"）
        await self.send_json(
            {"type": "joined", "slot": self.slot, "members": roster_before}
        )
        # 再告诉房间里其他人
        await self.channel_layer.group_send(
            self.room_group,
            {
                "type": "relay.control",
                "sender": self.channel_name,
                "message": {
                    "type": "member_joined",
                    "slot": self.slot,
                    "identity": member.identity,
                },
            },
        )
        logger.info(
            "voice audio join: channel=%s user=%s slot=%s", channel_id, member.identity, self.slot
        )

    async def disconnect(self, code):
        channel_id = getattr(self, "channel_id", None)
        if channel_id is None:
            return

        room_group = getattr(self, "room_group", None) or _audio_group_name(channel_id)
        member = await audio_relay.leave(channel_id, self.channel_name)
        try:
            await self.channel_layer.group_discard(room_group, self.channel_name)
        except Exception:  # 组可能已被销毁；不应阻塞断连清理
            logger.debug("group_discard failed for %s", room_group, exc_info=True)

        if member is not None:
            await self.channel_layer.group_send(
                room_group,
                {
                    "type": "relay.control",
                    "sender": self.channel_name,
                    "message": {"type": "member_left", "slot": member.slot},
                },
            )
            logger.info("voice audio leave: channel=%s slot=%s", channel_id, member.slot)

    async def receive(self, text_data=None, bytes_data=None):
        if getattr(self, "channel_id", None) is None:
            return

        if bytes_data:
            await self._handle_audio(bytes_data)
        elif text_data:
            await self._handle_control(text_data)

    # ---------- 媒体 ----------

    async def _handle_audio(self, payload: bytes):
        """裁决后转发；不解码、不改内容，只在前面加 1 字节 slot。"""
        slot = await audio_relay.may_relay(self.channel_id, self.channel_name)
        if slot is None:
            # 未标记在说话 / 已静音 / 不在 Top-K 内 —— 直接丢弃，不占用下行带宽
            return
        await self.channel_layer.group_send(
            self.room_group,
            {
                "type": "relay.audio",
                "sender": self.channel_name,
                "slot": slot,
                "payload": payload,
            },
        )

    # ---------- 控制 ----------

    async def _handle_control(self, text_data: str):
        import json

        try:
            content = json.loads(text_data)
        except (TypeError, ValueError):
            await self.send_json({"type": "error", "detail": "invalid json"})
            return

        msg_type = content.get("type")

        if msg_type == "ping":
            await self.send_json({"type": "pong", "ts": content.get("ts")})
            return

        if msg_type == "speaking":
            member = await audio_relay.set_speaking(
                self.channel_id, self.channel_name, bool(content.get("on"))
            )
            if member is not None:
                await self.channel_layer.group_send(
                    self.room_group,
                    {
                        "type": "relay.control",
                        "sender": self.channel_name,
                        "message": {
                            "type": "speaking",
                            "slot": member.slot,
                            "on": member.speaking,
                        },
                    },
                )
            return

        if msg_type == "mute":
            member = await audio_relay.set_muted(
                self.channel_id, self.channel_name, bool(content.get("on"))
            )
            if member is not None:
                await self.channel_layer.group_send(
                    self.room_group,
                    {
                        "type": "relay.control",
                        "sender": self.channel_name,
                        "message": {"type": "muted", "slot": member.slot, "on": member.muted},
                    },
                )
            return

        await self.send_json({"type": "error", "detail": f"unknown type {msg_type}"})

    # ---------- 组消息处理器 ----------

    async def relay_audio(self, event):
        """把别人的音频帧发给自己（[1 字节 slot] + Opus 包）。"""
        if event.get("sender") == self.channel_name:
            return  # 不回给自己：天然实现 N-1，避免自听/回声
        await self.send(bytes_data=bytes([event["slot"]]) + event["payload"])

    async def relay_control(self, event):
        if event.get("sender") == self.channel_name:
            return
        await self.send_json(event["message"])
