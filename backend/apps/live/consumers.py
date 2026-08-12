"""
直播弹幕 WebSocket Consumer —— `/ws/live/{channel_id}/?token=<jwt>`（M4-6 §5.2）。

- 认证复用 accounts presence WS 的 JWT query token 解析（`_jwt_user_from_scope`）；
- 连接即校验直播间存在：不存在/非法 → 关闭连接；
- 连接后加入 `live_{channel_id}` 组，收弹幕实时帧 `{"type":"danmaku", ...}`；
- 弹幕内容原样转发，应用不代判内容意义（AGENTS.md §2）。
"""
import logging

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer

from apps.accounts.consumers import _jwt_user_from_scope

from .services import _danmaku_group_name

logger = logging.getLogger(__name__)


@database_sync_to_async
def _channel_exists(channel_id) -> bool:
    from .models import LiveChannel

    try:
        LiveChannel.objects.get(pk=channel_id)
        return True
    except (LiveChannel.DoesNotExist, ValueError, TypeError):
        return False


class DanmakuConsumer(AsyncJsonWebsocketConsumer):
    """WS 订阅直播间弹幕（登录可见；JWT token 认证）。"""

    async def connect(self):
        self.user = await database_sync_to_async(_jwt_user_from_scope)(self.scope)
        if self.user is None:
            await self.close(code=4401)  # 未认证
            return
        self.channel_id = self.scope["url_route"]["kwargs"].get("channel_id")
        if not self.channel_id or not await _channel_exists(self.channel_id):
            logger.info("danmaku ws closed: channel %s missing", self.channel_id)
            await self.close(code=4404)  # 直播间不存在
            return
        self.group_name = _danmaku_group_name(self.channel_id)
        await self.channel_layer.group_add(self.group_name, self.channel_name)
        await self.accept()

    async def disconnect(self, code):
        group = getattr(self, "group_name", None)
        if group:
            await self.channel_layer.group_discard(group, self.channel_name)

    async def receive_json(self, content, **kwargs):
        msg_type = content.get("type")
        if msg_type == "ping":
            await self.send_json({"type": "pong", "ts": content.get("ts")})
        else:
            await self.send_json({"type": "error", "detail": f"unknown type {msg_type}"})

    # 组广播回调：danmaku（event["type"]="danmaku" → 同名方法）
    async def danmaku(self, event):
        await self.send_json(event)
