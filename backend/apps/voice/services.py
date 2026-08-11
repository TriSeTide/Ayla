"""
语音频道领域服务 —— REST 视图与 voice.state 广播复用的核心逻辑（M4-5 §6/§8）。

- 频道权限判断（复用 M4-2 `user_can_access` 语义）：真正权限判断是"是否在 `members` 里"，
  `channel.owner` 只是"创建者"语义；
- 加入/离开/心跳：写 `VoiceChannelMember` + 广播 `voice.state`；
- presence 心跳超时：超过 `VOICE_MEMBER_TIMEOUT_SECONDS` 未心跳的成员标记离开（后台任务 owner）；
- 广播复用 chat 的 `_group_send_sync/_group_send_async` 模式（捕获 ChannelFull 记 warning，不阻塞）。

硬约束（继承 AGENTS.md）：
- `voice.state` 只表达**技术状态**（joined/left/muted/unmuted/heartbeat），
  不是爱莉/用户的情绪判断（阶段三 §12.3 Provider 状态同理）；
- 每个订阅/后台任务必须有明确 owner、超时、取消与关闭路径。
"""
import logging
import uuid

from asgiref.sync import async_to_sync
from channels.exceptions import ChannelFull
from django.conf import settings
from django.db import IntegrityError, transaction
from django.utils import timezone

from .models import VoiceChannel, VoiceChannelMember

logger = logging.getLogger(__name__)


# ---------- 频道 ----------

def _gen_room_name() -> str:
    """自动生成 LiveKit Room 名（`room_<uuid hex>`，唯一、合法字符）。"""
    return f"room_{uuid.uuid4().hex}"


def create_channel(user, name: str) -> VoiceChannel:
    """建频道（自动生成唯一 room_name）。"""
    return VoiceChannel.objects.create(name=name, room_name=_gen_room_name(), owner=user)


def get_channel(channel_id) -> VoiceChannel | None:
    return VoiceChannel.objects.filter(pk=channel_id).first()


def channel_member(channel: VoiceChannel, user) -> VoiceChannelMember | None:
    return VoiceChannelMember.objects.filter(channel=channel, user=user).first()


def user_in_channel(channel: VoiceChannel, user) -> bool:
    """复用 M4-2 user_can_access 语义：真正权限判断是"是否在 members 里"。"""
    return channel_member(channel, user) is not None


def can_manage_channel(channel: VoiceChannel, user) -> bool:
    """频道 owner/管理员可改名称。"""
    return channel.owner_id == user.id


# ---------- 加入/离开/心跳 ----------

def join_channel(channel: VoiceChannel, user) -> VoiceChannelMember:
    """加入频道（幂等：已在成员表则刷新 last_seen_at）+ 广播 voice.state joined。"""
    with transaction.atomic():
        member, created = VoiceChannelMember.objects.get_or_create(
            channel=channel, user=user,
            defaults={"last_seen_at": timezone.now()},
        )
        if not created:
            member.last_seen_at = timezone.now()
            member.save(update_fields=["last_seen_at"])
    broadcast_voice_state(channel, user, "joined")
    return member


def leave_channel(channel: VoiceChannel, user) -> None:
    """离开频道（删除成员记录）+ 广播 voice.state left。"""
    deleted, _ = VoiceChannelMember.objects.filter(channel=channel, user=user).delete()
    if deleted:
        broadcast_voice_state(channel, user, "left")


def heartbeat_channel(channel: VoiceChannel, user) -> None:
    """presence 心跳：刷新 last_seen_at + 广播 voice.state heartbeat（可选）。"""
    member = channel_member(channel, user)
    if member is None:
        raise PermissionError("非频道成员不可心跳")
    member.last_seen_at = timezone.now()
    member.save(update_fields=["last_seen_at"])
    broadcast_voice_state(channel, user, "heartbeat")


def mark_stale_members_left(channel: VoiceChannel, timeout_seconds: int | None = None) -> int:
    """后台任务：把超过超时未心跳的成员标记离开（删除成员记录）+ 广播 voice.state left。

    返回清理的成员数。timeout 默认取 settings.VOICE_MEMBER_TIMEOUT_SECONDS。
    """
    timeout = timeout_seconds if timeout_seconds is not None else settings.VOICE_MEMBER_TIMEOUT_SECONDS
    cutoff = timezone.now() - timezone.timedelta(seconds=timeout)
    stale = list(
        VoiceChannelMember.objects.filter(channel=channel, last_seen_at__lt=cutoff)
    )
    for member in stale:
        member.delete()
        broadcast_voice_state(channel, member.user, "left")
    return len(stale)


# ---------- voice.state 广播 ----------

def _voice_state_event(channel: VoiceChannel, user, state: str) -> dict:
    return {
        "type": "voice.state",
        "data": {
            "channel_id": str(channel.id),
            "user_id": str(user.id),
            "state": state,
            "ts": timezone.now().isoformat(),
        },
    }


def _voice_group_name(channel_id) -> str:
    """语音频道组名（独立命名空间，避免与会话组 `chat_conv_{id}` 语义混淆/撞车）。"""
    return f"voice_chan_{channel_id}"


def broadcast_voice_state(channel: VoiceChannel, user, state: str) -> None:
    """同步广播（REST 视图用）：发到语音频道组 `voice_chan_{id}`，捕获 ChannelFull 不阻塞。"""
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    if layer is None:
        return
    try:
        async_to_sync(layer.group_send)(
            _voice_group_name(channel.id), _voice_state_event(channel, user, state)
        )
    except ChannelFull:
        logger.warning("channel full, dropping voice.state for vc %s", channel.id)
    except Exception:
        logger.exception("voice.state group_send failed for vc %s", channel.id)


async def abroadcast_voice_state(channel: VoiceChannel, user, state: str) -> None:
    """异步广播（WS/测试用）。"""
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    if layer is None:
        return
    try:
        await layer.group_send(
            _voice_group_name(channel.id), _voice_state_event(channel, user, state)
        )
    except ChannelFull:
        logger.warning("channel full, dropping voice.state for vc %s", channel.id)
    except Exception:
        logger.exception("voice.state group_send failed for vc %s", channel.id)
