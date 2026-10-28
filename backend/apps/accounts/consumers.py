"""
Presence WebSocket Consumer。

连接：`/ws/presence/?token=<jwt>`，握手时校验 JWT，失败关闭（协议 5 节）。
行为：
- 连接成功后标记用户在线（Redis），并广播 `presence.update`；
- 心跳 `ping` -> `pong`（保活，保持 Redis TTL）；
- 断开时**先注销本条连接的引用计数**：只有该账号最后一条 presence 连接断开才
  clear + 广播下线；其余连接仍在时保持在线（真因见
  Ayla/.workbuddy/evidence/livekit-udp/P4-WS-热更新-结论.md §7——同一账号 App + web
  并存、或重连时旧 socket close 晚到，都会把仍活着的新连接广播成 offline）。
"""
import json
import logging
from urllib.parse import parse_qs

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer
from django.contrib.auth import get_user_model
from rest_framework_simplejwt.tokens import AccessToken

from .presence import (
    clear_presence,
    purge_connection,
    refresh_connection,
    register_connection,
    set_presence,
    unregister_connection,
)

logger = logging.getLogger(__name__)

User = get_user_model()


def _jwt_user_from_scope(scope) -> "User | None":
    """从 query string 的 token 解析用户（同步工具函数）。"""
    query = parse_qs(scope.get("query_string", b"").decode("ascii", errors="ignore"))
    token_values = query.get("token")
    token = token_values[0] if token_values else ""
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
    # Presence 只表达「连接存在」：Redis 值恒为 online。
    # 隐身（invisible）是对外可见性语义，由 User.status（DB，实时）承载——
    # 运行中从隐身切回 auto 无需重连即可对外在线（get_online/display_status 查询 DB）。
    _PRESENCE_VALUE = "online"

    async def connect(self):
        self.user = await database_sync_to_async(_jwt_user_from_scope)(self.scope)
        if self.user is None:
            await self.close(code=4401)  # 未认证
            return
        self.presence_conn = self.channel_name  # 连接身份：Channels 保证单实例唯一
        self.presence_registered = False

        # 加入全局 presence 组（接收全站在线/离线广播）与个人定向组
        self.group_name = f"presence_{self.user.id}"
        await self.channel_layer.group_add("presence", self.channel_name)
        await self.channel_layer.group_add(self.group_name, self.channel_name)
        await self.accept()

        # 登记本条连接（引用计数 +1）：disconnect 时据此判断是否还有其它活连接
        await database_sync_to_async(register_connection)(
            self.user.id, self.presence_conn
        )
        self.presence_registered = True

        # 标记在线并广播；隐身用户记录 presence 但对外不广播在线（对外完全离线）
        set_presence(self.user.id, self._PRESENCE_VALUE)
        if self.user.status != User.STATUS_INVISIBLE:
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
        if not hasattr(self, "group_name"):
            return
        await self.channel_layer.group_discard(self.group_name, self.channel_name)
        await self.channel_layer.group_discard("presence", self.channel_name)

        # 注销本条连接：只有「该账号已无任何活连接」才下线；
        # 仍有其它连接（App + web 并存 / 重连重叠）时保持在线，不广播 offline。
        if getattr(self, "presence_registered", False):
            last_one = await database_sync_to_async(unregister_connection)(
                self.user.id, self.presence_conn
            )
        else:
            # connect 中途失败，连接可能已登记成功但本地标记未置位 → 按 channel_name 兜底摘除
            last_one = await database_sync_to_async(purge_connection)(
                self.channel_name
            )
        if last_one is not True:
            # False：还有其它活连接；None：存储不可用（无法证明是最后一条）
            # 两者都不许广播离线——错误下线正是本次修复要消除的症状。
            return

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
            # 心跳续期：账号 presence 值 + 本条连接的存活标记（崩溃后标记自然过期）
            if getattr(self, "presence_registered", False):
                await database_sync_to_async(refresh_connection)(
                    self.user.id, self.presence_conn, self._PRESENCE_VALUE
                )
            else:
                set_presence(self.user.id, self._PRESENCE_VALUE)

    async def presence_update(self, event):
        """组广播处理器（避免广播给自己造成回环）。"""
        await self.send_json(
            {
                "type": "presence.update",
                "data": {"user_id": event["user_id"], "status": event["status"]},
            }
        )

    async def presence_status(self, event):
        """状态模式变化广播（PATCH /me/profile/ 保存 status 时发出）。"""
        await self.send_json(
            {
                "type": "presence.status",
                "data": {"user_id": event["user_id"], "status": event["status"]},
            }
        )

    async def elysia_profile_updated(self, event):
        """爱莉 profile 变更（绑定用户/启用位）→ 广播给所有在线用户。"""
        await self.send_json(
            {
                "type": "elysia.profile.updated",
                "data": {
                    "user_id": event.get("user_id"),
                    "enabled": event.get("enabled"),
                },
            }
        )

    async def user_updated(self, event):
        """公开资料变更广播（普查 W3：昵称/头像/签名，PATCH /me/profile/ 时发出）。"""
        await self.send_json(
            {
                "type": "user.updated",
                "data": {
                    "user_id": event["user_id"],
                    "nickname": event.get("nickname", ""),
                    "avatar": event.get("avatar", ""),
                    "signature": event.get("signature", ""),
                },
            }
        )
