"""直播弹幕 + 在看人数 WebSocket Consumer —— `/ws/live/{channel_id}/?token=<jwt>`（M4-6 §5.2）。

- 认证复用 accounts presence WS 的 JWT query token 解析（`_jwt_user_from_scope`）；
- 连接即校验直播间存在：不存在/非法 → 关闭连接；
- 连接后加入 `live_{channel_id}` 组，收弹幕实时帧 `{"type":"danmaku", ...}` 与
  在看人数帧 `{"type":"viewers", ...}`；
- **连接本身就是在看直播的运行事实**：建立时登记 viewer presence、断开时移除，
  人数变化同时广播房内帧（含头像预览）与 `live_catalog` 目录帧（仅人数）；
  心跳 ping 刷新活跃分，若此前已被判为离开则补一次人数广播（避免人数无声变化）；
- 弹幕内容原样转发，应用不代判内容意义（AGENTS.md §2）。
"""
import logging

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer

from apps.accounts.consumers import _jwt_user_from_scope

from . import services, viewers
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
        # 入组完成后再登记在看：广播能同时送达本人与房间其他观众。
        self.viewer_registered = True
        await self._sync_viewers()

    async def disconnect(self, code):
        group = getattr(self, "group_name", None)
        if group:
            await self.channel_layer.group_discard(group, self.channel_name)
        if getattr(self, "viewer_registered", False):
            self.viewer_registered = False
            await self._sync_viewers(present=False)

    async def receive_json(self, content, **kwargs):
        msg_type = content.get("type")
        if msg_type == "ping":
            await self.send_json({"type": "pong", "ts": content.get("ts")})
            await self._refresh_viewer_presence()
        else:
            await self.send_json({"type": "error", "detail": f"unknown type {msg_type}"})

    # ---------- 在看人数（Viewer Presence） ----------

    async def _sync_viewers(self, *, present: bool = True) -> None:
        """登记/移除本人 presence，并把新的在看人数广播出去。

        presence 存储不可用（`count is None`）时不广播——**不能把读不到伪装成 0 人**；
        房内帧与目录帧由 services 一并投递。
        """
        if present:
            await database_sync_to_async(viewers.add_viewer)(
                self.channel_id, self.user.id
            )
        else:
            await database_sync_to_async(viewers.remove_viewer)(
                self.channel_id, self.user.id
            )
        count, preview = await database_sync_to_async(services.viewer_snapshot)(
            self.channel_id
        )
        if count is None:
            return
        await services.abroadcast_viewers(self.channel_id, count, preview)

    async def _refresh_viewer_presence(self) -> None:
        """心跳刷新活跃分；此前已被判为离开时补播一次人数（人数变化必须可见）。"""
        rejoined = await database_sync_to_async(viewers.touch_viewer)(
            self.channel_id, self.user.id
        )
        if not rejoined:
            return
        count, preview = await database_sync_to_async(services.viewer_snapshot)(
            self.channel_id
        )
        if count is None:
            return
        await services.abroadcast_viewers(self.channel_id, count, preview)

    # 组广播回调：danmaku（event["type"]="danmaku" → 同名方法）
    async def danmaku(self, event):
        await self.send_json(event)

    # 组广播回调：在看人数帧（event["type"]="viewers" → 同名方法）
    async def viewers(self, event):
        await self.send_json(event)
