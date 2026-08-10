"""
Presence WebSocket Consumer。

连接：`/ws/presence/?token=<jwt>`，握手时校验 JWT，失败关闭（协议 5 节）。
行为：
- 连接成功后标记用户在线（Redis），并广播 `presence.update`；
- 心跳 `ping` -> `pong`（保活，保持 Redis TTL）；
- 断开时清理在线状态并广播下线。
"""
import json
import logging

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer
from django.contrib.auth import get_user_model
from rest_framework_simplejwt.tokens import AccessToken

from .presence import clear_presence, set_presence

logger = logging.getLogger(__name__)

User = get_user_model()


def _jwt_user_from_scope(scope) -> "User | None":
    """从 query string 的 token 解析用户（同步工具函数）。"""
    token = scope["query_string"].decode().removeprefix("token=")
    # 支持 token=xxx 或 token=xxx&extra=yyy
    if "&" in token:
        token = token.split("&")[0]
    if not token:
        return None
    try:
        access = AccessToken(token)
        user_id = access["user_id"]
        return User.objects.filter(pk=user_id).first()
    except Exception:
        logger.warning("presence ws auth failed", exc_info=True)
        return None


class PresenceConsumer(AsyncJsonWebsocketConsumer):
    async def connect(self):
        self.user = await database_sync_to_async(_jwt_user_from_scope)(self.scope)
        if self.user is None:
            await self.close(code=4401)  # 未认证
            return

        self.group_name = f"presence_{self.user.id}"
        await self.channel_layer.group_add(self.group_name, self.channel_name)
        await self.accept()

        # 标记在线并广播
        set_presence(self.user.id, self.user.status or "online")
        await self.channel_layer.group_send(
            "presence",
            {
                "type": "presence.update",
                "user_id": self.user.id,
                "status": "online",
            },
        )
        # 推送自己的实时状态
        await self.send_json({"type": "presence.self", "data": {"user_id": self.user.id}})

    async def disconnect(self, code):
        if hasattr(self, "group_name"):
            await self.channel_layer.group_discard(self.group_name, self.channel_name)
            clear_presence(self.user.id)
            await self.channel_layer.group_send(
                "presence",
                {
                    "type": "presence.update",
                    "user_id": self.user.id,
                    "status": "offline",
                },
            )

    async def receive_json(self, content, **kwargs):
        msg_type = content.get("type")
        if msg_type == "ping":
            await self.send_json({"type": "pong", "ts": content.get("ts")})
            # 心跳续期
            set_presence(self.user.id, self.user.status or "online")

    async def presence_update(self, event):
        """组广播处理器（避免广播给自己造成回环）。"""
        await self.send_json(
            {
                "type": "presence.update",
                "data": {"user_id": event["user_id"], "status": event["status"]},
            }
        )
