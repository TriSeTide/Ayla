"""
直播领域服务（M4-6 §4/§5）—— 频道生命周期、地址生成、SRS 状态判定、弹幕落库+广播。

设计要点（复用 M4-5 voice.state 模式）：
- 弹幕落库与广播分离：REST 视图内 `database_sync_to_async` 落库 → 广播走 channels group
  （`live_{channel_id}`），同步版（async_to_sync）与异步版（直接 await）并存，
  避免在事件循环线程里同步调 group_send（M4-5 教训）；
- 状态判定：应用侧 `status` 是乐观标记（:start/:stop 更新）；"是否在播"以
  `srs.is_streaming("live", stream_key)` 实时判定为准，SRS 查询失败返回 degraded
  （不伪装"未在播"，AGENTS.md §8）；
- 广播捕获 ChannelFull 记 warning，不阻塞其他消费者；
- 弹幕内容原样广播，应用不代判内容意义（AGENTS.md §2 认知零规则）。
"""
import logging
import secrets

from asgiref.sync import async_to_sync
from channels.exceptions import ChannelFull
from channels.layers import get_channel_layer
from django.conf import settings
from django.db import transaction
from django.utils import timezone

from apps.common.visibility import Visibility

from .models import Danmaku, LiveChannel
from .srs import SrsClient, SrsUnavailable, get_srs

logger = logging.getLogger(__name__)

# 弹幕历史上限（?limit= 允许的最大值）
DANMAKU_HISTORY_MAX = 200


# ---------- 频道生命周期 ----------

def gen_stream_key() -> str:
    """生成推流握手指纹（secrets.token_hex(24) = 48 字符 ≤ 64）。"""
    return secrets.token_hex(24)


def _resolve_visibility(group, visibility: str | None) -> str:
    """S1 可见性默认：group 非空且未显式指定 → group 可见；否则 public。

    约束：visibility=group 的群可见性由 allowed_group_ids 白名单提供（group FK 不承载
    可见性）；group 为空时仍允许返回 GROUP（多群白名单场景），"两者皆空"由视图层校验。
    """
    if visibility is None or not visibility:
        return Visibility.GROUP if group is not None else Visibility.PUBLIC
    return visibility


def create_channel(
    user,
    title: str,
    group=None,
    visibility: str | None = None,
    description: str = "",
    cover: str = "",
    allowed_group_ids=None,
) -> LiveChannel:
    """创建直播频道：生成唯一 stream_key（DB 唯一索引兜底，碰撞重试）。

    S1 扩展：可选 `group`（FK chat.Conversation，须为群聊）与 `visibility`。
    """
    title = (title or "").strip()
    if not title:
        raise ValueError("title 不能为空")
    description = (description or "").strip()
    if len(description) > 2000:
        raise ValueError("description 不能超过 2000 字")
    cover = (cover or "").strip()
    if group is not None:
        if str(getattr(group, "type", "")) != "group":
            raise ValueError("group 必须是群聊会话")
    visibility = _resolve_visibility(group, visibility)
    for _ in range(5):
        key = gen_stream_key()
        if not LiveChannel.objects.filter(stream_key=key).exists():
            channel = LiveChannel.objects.create(
                title=title,
                description=description,
                cover=cover,
                owner=user,
                stream_key=key,
                group=group,
                visibility=visibility,
            )
            if allowed_group_ids is not None:
                from apps.common.visibility import set_allowed_groups
                set_allowed_groups(channel, allowed_group_ids)
            elif visibility == Visibility.GROUP and group is not None:
                # 兜底：群内创建未显式传白名单时，把归属群落为白名单，
                # 使群可见性完全由 allowed_groups 表达（group FK 不承载可见性）。
                from apps.common.visibility import set_allowed_groups
                set_allowed_groups(channel, [str(group.id)])
            return channel
    raise RuntimeError("stream_key 生成冲突（多次重试仍碰撞）")


def get_channel(channel_id) -> LiveChannel | None:
    return LiveChannel.objects.filter(pk=channel_id).first()


def can_manage_channel(channel: LiveChannel, user) -> bool:
    """频道 owner 可 :start/:stop/删除。"""
    return channel.owner_id == user.id


# ---------- 地址生成 ----------

def build_rtmp_url(channel: LiveChannel) -> str:
    """RTMP 推流地址 `rtmp://<host>:1935/live/{stream_key}`（仅 owner 可见）。"""
    return f"{settings.SRS_RTMP_URL.rstrip('/')}/{channel.stream_key}"


def build_hls_url(channel: LiveChannel) -> str:
    """HLS 播放地址 `http://<host>:8080/live/{stream_key}.m3u8`（全员可见）。"""
    return f"{settings.SRS_PLAY_URL.rstrip('/')}/{channel.stream_key}.m3u8"


def build_flv_url(channel: LiveChannel) -> str:
    """HTTP-FLV 播放地址 `http://<host>:8080/live/{stream_key}.flv`（全员可见）。"""
    return f"{settings.SRS_PLAY_URL.rstrip('/')}/{channel.stream_key}.flv"


# ---------- 乐观标记 :start / :stop ----------

@transaction.atomic
def start_channel(channel: LiveChannel) -> LiveChannel:
    """开播；同一 owner 同时只能有一个 live 频道。"""
    owner_model = channel.owner.__class__
    owner_model.objects.select_for_update().get(pk=channel.owner_id)
    if LiveChannel.objects.filter(
        owner=channel.owner, status="live"
    ).exclude(pk=channel.pk).exists():
        raise ValueError("你已有一个直播间正在开播，请先结束当前直播")
    channel.status = "live"
    channel.started_at = timezone.now()
    channel.save(update_fields=["status", "started_at"])
    owner = channel.owner
    owner.is_live = True
    owner.live_room_id = channel.id
    owner.save(update_fields=["is_live", "live_room_id"])
    return channel


def stop_channel(channel: LiveChannel) -> LiveChannel:
    """下播（乐观标记：status→ended、ended_at=now）。"""
    channel.status = "ended"
    channel.ended_at = timezone.now()
    channel.save(update_fields=["status", "ended_at"])
    owner = channel.owner
    if owner.live_room_id == channel.id:
        owner.is_live = False
        owner.live_room_id = None
        owner.save(update_fields=["is_live", "live_room_id"])
    return channel


# ---------- SRS 状态判定 ----------

def resolve_live_status(channel: LiveChannel, srs: SrsClient | None = None) -> dict:
    """SRS 实时判定"是否在播"（AGENTS.md §8：查询失败不伪装"未在播"）。

    返回：
    - SRS 在播 → {"status": "live", "source": "srs", "optimistic": channel.status}
    - SRS 未在播 → {"status": "idle", "source": "srs", "optimistic": channel.status}
    - SRS 查询失败 → {"status": "degraded", "source": "srs_unavailable",
      "detail": "srs_unavailable", "optimistic": channel.status}
    """
    srs = srs or get_srs()
    optimistic = channel.status
    try:
        streaming = srs.is_streaming("live", channel.stream_key)
    except SrsUnavailable:
        logger.warning("srs query failed for channel %s (stream_key masked)", channel.id)
        return {
            "status": "degraded",
            "source": "srs_unavailable",
            "detail": "srs_unavailable",
            "optimistic": optimistic,
        }
    return {
        "status": "live" if streaming else "idle",
        "source": "srs",
        "detail": None,
        "optimistic": optimistic,
    }


# ---------- 弹幕 ----------

def _sender_descriptor(user) -> dict:
    """sender 序列化（昵称/头像；content 原样不代判）。"""
    return {
        "user_id": str(user.id),
        "nickname": user.nickname or "",
        "avatar": user.avatar or "",
    }


def create_danmaku(
    channel: LiveChannel,
    user,
    content: str,
    media_id: str | None = None,
) -> Danmaku:
    """发弹幕：文本长度与图片引用校验后落库，广播由调用方负责。"""
    content = (content or "").strip()
    media_id = (media_id or "").strip() or None
    if not content and not media_id:
        raise ValueError("content 不能为空")
    if len(content) > 200:
        raise ValueError("content 长度不能超过 200")
    if media_id:
        from apps.media.models import MediaObject
        from apps.media.services import can_access_media

        media = MediaObject.objects.filter(media_id=media_id).first()
        if media is None:
            raise ValueError("media_not_found")
        if media.status != MediaObject.STATUS_READY:
            raise ValueError("media_not_ready")
        if media.kind != MediaObject.KIND_IMAGE:
            raise ValueError("media_type_mismatch")
        if not can_access_media(user, media):
            raise PermissionError("media_access_denied")
    return Danmaku.objects.create(
        channel=channel,
        sender=user,
        content=content or "图片",
        media_id=media_id,
    )


def danmaku_history(channel: LiveChannel, limit: int | None = None) -> list[Danmaku]:
    """最近弹幕（默认 LIVE_DANMAKU_HISTORY_LIMIT，上限 200），按时间升序返回。"""
    if limit is None:
        limit = settings.LIVE_DANMAKU_HISTORY_LIMIT
    limit = max(1, min(int(limit), DANMAKU_HISTORY_MAX))
    rows = list(
        Danmaku.objects.filter(channel=channel).order_by("-created_at")[:limit]
    )
    rows.reverse()  # 升序（新进房间按时间正序展示）
    return rows


def _media_descriptor(media_id: str | None) -> dict | None:
    if not media_id:
        return None
    from apps.media.models import MediaObject
    from apps.media.serializers import MediaObjectSerializer

    media = MediaObject.objects.filter(media_id=media_id).first()
    return MediaObjectSerializer(media).data if media is not None else None


def _danmaku_event(dm: Danmaku) -> dict:
    return {
        "type": "danmaku",
        "id": str(dm.id),
        "channel_id": str(dm.channel_id),
        "sender": _sender_descriptor(dm.sender),
        "content": dm.content,
        "media_id": dm.media_id,
        "media": _media_descriptor(dm.media_id),
        "created_at": dm.created_at.isoformat(),
    }


def _danmaku_group_name(channel_id) -> str:
    """弹幕组名：`live_{channel_id}`（M4-6 §5.2）。"""
    return f"live_{channel_id}"


def broadcast_danmaku(dm: Danmaku) -> None:
    """同步广播（REST 视图用）：发到 `live_{channel_id}` 组，捕获 ChannelFull 不阻塞。"""
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    if layer is None:
        return
    try:
        async_to_sync(layer.group_send)(
            _danmaku_group_name(dm.channel_id), _danmaku_event(dm)
        )
    except ChannelFull:
        logger.warning("channel full, dropping danmaku for live %s", dm.channel_id)
    except Exception:
        logger.exception("danmaku group_send failed for live %s", dm.channel_id)


async def abroadcast_danmaku(dm: Danmaku) -> None:
    """异步广播（WS/测试用）。"""
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    if layer is None:
        return
    try:
        await layer.group_send(
            _danmaku_group_name(dm.channel_id), _danmaku_event(dm)
        )
    except ChannelFull:
        logger.warning("channel full, dropping danmaku for live %s", dm.channel_id)
    except Exception:
        logger.exception("danmaku group_send failed for live %s", dm.channel_id)


# ---------- 直播间实时推送 ----------

def _channel_event(channel, event_type: str, **extra) -> dict:
    """Build a minimal event; recipients are selected server-side by visibility."""
    return {
        "type": event_type,
        "channel_id": channel.id,
        "name": channel.title,
        "owner_id": str(channel.owner_id),
        "visibility": channel.visibility,
        "group_id": str(channel.group_id) if channel.group_id else None,
        "status": channel.status,
        "created_at": channel.created_at.isoformat(),
        **extra,
    }


def _visible_recipient_ids(channel) -> set[str]:
    """Return users allowed to receive a live-channel invalidation event.

    Events contain no stream credentials.  The client still reconciles the
    descriptor through REST, so this recipient set is the server-side
    visibility boundary rather than a client-side filter.
    """
    from apps.accounts.models import Friendship
    from apps.chat.models import ConversationMember

    ids = {str(channel.owner_id)}
    if channel.visibility == Visibility.PUBLIC:
        ids.update(str(value) for value in channel.owner.__class__.objects.values_list("id", flat=True))
    elif channel.visibility == Visibility.FRIENDS:
        ids.update(str(value) for value in Friendship.objects.filter(
            user_id=channel.owner_id, status=Friendship.STATUS_ACCEPTED
        ).values_list("friend_id", flat=True))
    # 群可见性仅由白名单提供（归属群 group FK 不承载可见性）
    allowed_ids = list(channel.allowed_groups.values_list("id", flat=True))
    if allowed_ids:
        ids.update(str(value) for value in ConversationMember.objects.filter(
            conversation_id__in=allowed_ids
        ).values_list("user_id", flat=True))
    return ids


def _broadcast_to_users(event: dict, user_ids: set[str]) -> None:
    layer = get_channel_layer()
    if layer is None:
        return
    for user_id in user_ids:
        try:
            async_to_sync(layer.group_send)(f"chat_user_{user_id}", event)
        except ChannelFull:
            logger.warning("live event dropped for user %s", user_id)
        except Exception:
            logger.exception("live event broadcast failed for user %s", user_id)


def broadcast_channel_created_to_group(channel, group):
    """Backward-compatible entry point; visibility is always enforced centrally."""
    _broadcast_to_users(_channel_event(channel, "live.channel.created"), _visible_recipient_ids(channel))


def broadcast_channel_created_to_user(channel, user):
    """Backward-compatible entry point; visibility is always enforced centrally."""
    _broadcast_to_users(_channel_event(channel, "live.channel.created"), _visible_recipient_ids(channel))


def broadcast_channel_status_changed(channel, new_status):
    """Notify every currently authorized viewer, not only a subscribed group."""
    event = _channel_event(
        channel, "live.channel.status.changed", changed_at=timezone.now().isoformat(),
        status=new_status,
    )
    _broadcast_to_users(event, _visible_recipient_ids(channel))


def broadcast_channel_deleted(channel_id, recipient_ids=None):
    """Notify the precomputed authorized viewers before the row is deleted."""
    event = {"type": "live.channel.deleted", "channel_id": channel_id}
    _broadcast_to_users(event, {str(value) for value in (recipient_ids or [])})


def broadcast_channel_updated(channel) -> None:
    """直播间资料被编辑（标题/封面/可见性）后广播：与 created 相同收件人范围。

    前端收到后按权限 REST 对账完整 descriptor，轮播「直播卡」（封面/标题）据此实时刷新。
    """
    event = _channel_event(channel, "live.channel.updated")
    _broadcast_to_users(event, _visible_recipient_ids(channel))
