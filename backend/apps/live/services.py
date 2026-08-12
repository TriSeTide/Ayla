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
from django.conf import settings
from django.utils import timezone

from .models import Danmaku, LiveChannel
from .srs import SrsClient, SrsUnavailable, get_srs

logger = logging.getLogger(__name__)

# 弹幕历史上限（?limit= 允许的最大值）
DANMAKU_HISTORY_MAX = 200


# ---------- 频道生命周期 ----------

def gen_stream_key() -> str:
    """生成推流握手指纹（secrets.token_hex(24) = 48 字符 ≤ 64）。"""
    return secrets.token_hex(24)


def create_channel(user, title: str) -> LiveChannel:
    """创建直播频道：生成唯一 stream_key（DB 唯一索引兜底，碰撞重试）。"""
    title = (title or "").strip()
    if not title:
        raise ValueError("title 不能为空")
    for _ in range(5):
        key = gen_stream_key()
        if not LiveChannel.objects.filter(stream_key=key).exists():
            return LiveChannel.objects.create(
                title=title, owner=user, stream_key=key
            )
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

def start_channel(channel: LiveChannel) -> LiveChannel:
    """开播（乐观标记：status→live、started_at=now；不校验 SRS 真实流，由 /status 判定）。"""
    channel.status = "live"
    channel.started_at = timezone.now()
    channel.save(update_fields=["status", "started_at"])
    return channel


def stop_channel(channel: LiveChannel) -> LiveChannel:
    """下播（乐观标记：status→ended、ended_at=now）。"""
    channel.status = "ended"
    channel.ended_at = timezone.now()
    channel.save(update_fields=["status", "ended_at"])
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


def create_danmaku(channel: LiveChannel, user, content: str) -> Danmaku:
    """发弹幕：内容校验（非空、≤200）+ 落库。广播由调用方负责（落库与广播分离）。"""
    content = (content or "").strip()
    if not content:
        raise ValueError("content 不能为空")
    if len(content) > 200:
        raise ValueError("content 长度不能超过 200")
    return Danmaku.objects.create(channel=channel, sender=user, content=content)


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


def _danmaku_event(dm: Danmaku) -> dict:
    return {
        "type": "danmaku",
        "id": str(dm.id),
        "channel_id": str(dm.channel_id),
        "sender": _sender_descriptor(dm.sender),
        "content": dm.content,
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
