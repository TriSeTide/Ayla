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
from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from django.utils import timezone

from apps.common.visibility import Visibility

from .models import VoiceChannel, VoiceChannelMember

logger = logging.getLogger(__name__)


# ---------- 频道 ----------

def _gen_room_name() -> str:
    """自动生成 LiveKit Room 名（`room_<uuid hex>`，唯一、合法字符）。"""
    return f"room_{uuid.uuid4().hex}"


def _resolve_visibility(group, visibility: str | None) -> str:
    """S1 可见性默认：group 非空且未显式指定 → group 可见；否则 public。

    visibility=group 的群可见性由 `allowed_groups` 白名单提供（group FK 不承载可见性）。
    group 为空时仍允许返回 GROUP（全局"指定群可见"多群场景），"两者皆空"的校验由
    视图层在拿到完整 payload 后执行（见 views.py ChannelListView.post）。
    """
    if visibility is None or not visibility:
        return Visibility.GROUP if group is not None else Visibility.PUBLIC
    return visibility


def create_channel(user, name: str, group=None, visibility: str | None = None, allowed_group_ids=None) -> VoiceChannel:
    """建频道（自动生成唯一 room_name）。

    S1 扩展：可选 `group`（FK chat.Conversation，须为群聊）与 `visibility`。
    """
    if group is not None:
        if str(getattr(group, "type", "")) != "group":
            raise ValueError("group 必须是群聊会话")
    visibility = _resolve_visibility(group, visibility)
    channel = VoiceChannel.objects.create(
        name=name,
        room_name=_gen_room_name(),
        owner=user,
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


@transaction.atomic
def delete_channel(channel: VoiceChannel, actor) -> None:
    """删除频道并清理所有成员的跨页活动标记。"""
    locked = VoiceChannel.objects.select_for_update().get(pk=channel.pk)
    if locked.owner_id != actor.id:
        raise PermissionError("仅房主可删除")
    member_ids = list(
        VoiceChannelMember.objects.filter(channel=locked).values_list("user_id", flat=True)
    )
    VoiceChannelMember.objects.filter(channel=locked).delete()
    User = get_user_model()
    User.objects.filter(pk__in=member_ids, voice_room_id=locked.id).update(
        is_in_voice=False, voice_room_id=None
    )
    locked.delete()


def get_channel(channel_id) -> VoiceChannel | None:
    return VoiceChannel.objects.filter(pk=channel_id).first()


def channel_member(channel: VoiceChannel, user) -> VoiceChannelMember | None:
    return VoiceChannelMember.objects.filter(channel=channel, user=user).first()


def user_in_channel(channel: VoiceChannel, user) -> bool:
    """复用 M4-2 user_can_access 语义：真正权限判断是"是否在 members 里"。"""
    return channel_member(channel, user) is not None


def can_manage_channel(channel: VoiceChannel, user) -> bool:
    """频道 owner 可管理频道。"""
    return channel.owner_id == user.id


@transaction.atomic
def transfer_channel_owner(channel: VoiceChannel, actor, target_user_id):
    """将语音房房主转给当前成员；不能转让给自己。"""
    locked_channel = VoiceChannel.objects.select_for_update().get(pk=channel.pk)
    if locked_channel.owner_id != actor.id:
        raise PermissionError("仅房主可转让")
    if str(target_user_id) == str(actor.id):
        raise ValueError("不能转让给自己")
    target = VoiceChannelMember.objects.select_related("user").select_for_update().get(
        channel=locked_channel, user_id=target_user_id
    )
    locked_channel.owner_id = target.user_id
    locked_channel.save(update_fields=["owner"])
    # 保持调用方持有的实例与数据库一致，避免同一请求链上的后续权限判断使用旧 owner_id。
    channel.owner_id = target.user_id
    # 房主变更 → 目录与房内实时对账（owner 标识 / 踢人转让按钮 / 删除按钮刷新）。
    broadcast_channel_updated(channel)
    return channel


def kick_member(channel: VoiceChannel, actor, user_id):
    """房主踢出成员，不能踢自己。"""
    if not can_manage_channel(channel, actor):
        raise PermissionError("仅房主可踢人")
    if str(user_id) == str(actor.id):
        raise ValueError("不能踢自己")
    member = VoiceChannelMember.objects.filter(channel=channel, user_id=user_id).first()
    if member is None:
        raise LookupError("成员不存在")
    user = member.user
    member.delete()
    broadcast_voice_state(channel, user, "left")
    broadcast_channel_member_count(channel)
    if member.user.voice_room_id == channel.id:
        member.user.is_in_voice = False
        member.user.voice_room_id = None
        member.user.save(update_fields=["is_in_voice", "voice_room_id"])
    broadcast_voice_state(channel, member.user, "left")


# ---------- 加入/离开/心跳 ----------

def join_channel(channel: VoiceChannel, user) -> VoiceChannelMember:
    """加入频道；同一用户始终只保留一个语音房成员关系。

    切换房间时先删除旧成员关系并广播离开，再创建/刷新目标成员关系；
    整个数据库变更在一个事务内完成，避免并发 join 留下多个房间状态。
    """
    with transaction.atomic():
        user.__class__.objects.select_for_update().get(pk=user.pk)
        previous_ids = list(
            VoiceChannelMember.objects.select_for_update()
            .filter(user=user)
            .exclude(channel=channel)
            .values_list("channel_id", flat=True)
        )
        if previous_ids:
            VoiceChannelMember.objects.filter(
                user=user, channel_id__in=previous_ids
            ).delete()
        member, created = VoiceChannelMember.objects.get_or_create(
            channel=channel, user=user,
            defaults={"last_seen_at": timezone.now()},
        )
        if not created:
            member.last_seen_at = timezone.now()
            member.save(update_fields=["last_seen_at"])
        user.is_in_voice = True
        user.voice_room_id = channel.id
        user.save(update_fields=["is_in_voice", "voice_room_id"])
    for previous_id in previous_ids:
        broadcast_voice_state_by_channel_id(previous_id, user, "left")
        # 旧频道有人离开 → 目录人数实时刷新（否则旧房间卡片人数不减，像"没退掉"）
        broadcast_channel_member_count_by_id(previous_id)
    broadcast_voice_state(channel, user, "joined")
    # 有人进入 → 目录人数实时刷新（轮播「N人在xx连麦」/「有人在语音房」）
    broadcast_channel_member_count(channel)
    return member


def leave_channel(channel: VoiceChannel, user) -> None:
    """离开频道。

    生命周期契约：
    - 房主可直接离开（不再要求先转让）；频道 owner 归属保持不变，
      房主离开后若仍有其他成员在场，频道继续存在，owner 仍是原房主。
    锁行后重读 owner，避免与并发转让/踢人竞态造成基于旧 owner 的误判。
    """
    with transaction.atomic():
        locked = VoiceChannel.objects.select_for_update().get(pk=channel.pk)
        deleted, _ = VoiceChannelMember.objects.filter(
            channel=locked, user=user
        ).delete()
        # 保持调用方实例的 owner 与数据库一致，避免同链上后续判断用旧值。
        channel.owner_id = locked.owner_id
    if deleted:
        if user.voice_room_id == channel.id:
            user.is_in_voice = False
            user.voice_room_id = None
            user.save(update_fields=["is_in_voice", "voice_room_id"])
        broadcast_voice_state(channel, user, "left")
        # 有人离开 → 目录人数实时刷新
        broadcast_channel_member_count(channel)


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
        if member.user.voice_room_id == channel.id:
            member.user.is_in_voice = False
            member.user.voice_room_id = None
            member.user.save(update_fields=["is_in_voice", "voice_room_id"])
        broadcast_voice_state(channel, member.user, "left")
    if stale:
        # 超时清理后目录人数实时刷新
        broadcast_channel_member_count(channel)
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


def broadcast_voice_state_by_channel_id(channel_id, user, state: str) -> None:
    """按已删除成员关系的频道 id 广播离开事件。"""
    channel = VoiceChannel(id=channel_id)
    broadcast_voice_state(channel, user, state)


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


# ---------- 语音房创建/删除推送 ----------

def _broadcast_channel_catalog_event(channel_id: str, event_type: str) -> None:
    """广播目录变更提示；元数据必须由客户端通过权限 REST 获取。"""
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    if layer is None:
        return
    try:
        async_to_sync(layer.group_send)(
            "voice_catalog",
            {"type": event_type, "channel_id": str(channel_id)},
        )
    except ChannelFull:
        logger.warning("%s broadcast dropped (ChannelFull)", event_type)
    except Exception:
        logger.exception("%s broadcast failed for channel %s", event_type, channel_id)


def broadcast_channel_created_to_group(channel, group):
    """提示所有在线客户端对账新频道；详情仍由 REST 可见性控制。"""
    _broadcast_channel_catalog_event(channel.id, "voice.channel.created")


def broadcast_channel_created_to_user(channel, user):
    """兼容旧调用点；目录事件已统一由全局目录组发送。"""
    _broadcast_channel_catalog_event(channel.id, "voice.channel.created")


def broadcast_channel_deleted(channel_id, visibility, group_id=None):
    """语音房删除推送"""
    from channels.layers import get_channel_layer

    try:
        layer = get_channel_layer()
        event = {
            "type": "voice.channel.deleted",
            "channel_id": str(channel_id),
        }
        async_to_sync(layer.group_send)("voice_catalog", event)
    except ChannelFull:
        logger.warning("voice.channel.deleted broadcast dropped")
    except Exception:
        logger.exception("voice.channel.deleted broadcast failed")


def broadcast_channel_updated(channel) -> None:
    """语音房元数据变更（改名/可见性/转让房主）→ 目录实时对账。

    只携带 channel_id，元数据由各客户端经权限 REST 详情获取（与 created/deleted
    同模式），避免向无权用户泄露好友/群白名单频道的改名内容。
    """
    _broadcast_channel_catalog_event(channel.id, "voice.channel.updated")


def broadcast_voice_chat_message(channel, message_payload: dict) -> None:
    """房内聊天消息广播到频道组 `voice_chan_{id}`（房内成员实时收到新消息）。

    message_payload 为 views._payload(message) 的序列化结果（含 sender/media），
    与 POST messages/ 返回结构一致，客户端按 message.id 幂等去重。
    """
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    if layer is None:
        return
    try:
        async_to_sync(layer.group_send)(
            _voice_group_name(channel.id),
            {"type": "voice.chat.message", "data": message_payload},
        )
    except ChannelFull:
        logger.warning(
            "voice.chat.message broadcast dropped (ChannelFull) for vc %s", channel.id
        )
    except Exception:
        logger.exception(
            "voice.chat.message broadcast failed for vc %s", channel.id
        )


def broadcast_channel_member_count(channel) -> None:
    """语音房成员数变动后广播目录更新（有人加入/离开/被踢/超时清理）。

    轮播「N人在xx连麦」与「有人在语音房」据此实时刷新；事件直接携带
    member_count（人数不涉权限元数据），客户端 patch 即可，无需 REST 对账。
    """
    from channels.layers import get_channel_layer
    from channels.exceptions import ChannelFull

    layer = get_channel_layer()
    if layer is None:
        return
    member_count = VoiceChannelMember.objects.filter(channel=channel).count()
    try:
        async_to_sync(layer.group_send)(
            "voice_catalog",
            {
                "type": "voice.channel.member_count_changed",
                "channel_id": str(channel.id),
                "member_count": member_count,
            },
        )
    except ChannelFull:
        logger.warning(
            "voice.channel.member_count_changed broadcast dropped (ChannelFull) for vc %s",
            channel.id,
        )
    except Exception:
        logger.exception(
            "voice.channel.member_count_changed broadcast failed for vc %s",
            channel.id,
        )


def broadcast_channel_member_count_by_id(channel_id) -> None:
    """按频道 id 广播成员数（切换房间时旧频道成员关系已删除，仅有 id）。

    与 broadcast_channel_member_count 同语义，但接受裸 id，避免为已删成员关系的
    旧频道重建 ORM 对象。
    """
    from channels.layers import get_channel_layer
    from channels.exceptions import ChannelFull

    layer = get_channel_layer()
    if layer is None:
        return
    member_count = VoiceChannelMember.objects.filter(channel_id=channel_id).count()
    try:
        async_to_sync(layer.group_send)(
            "voice_catalog",
            {
                "type": "voice.channel.member_count_changed",
                "channel_id": str(channel_id),
                "member_count": member_count,
            },
        )
    except ChannelFull:
        logger.warning(
            "voice.channel.member_count_changed broadcast dropped (ChannelFull) for vc %s",
            channel_id,
        )
    except Exception:
        logger.exception(
            "voice.channel.member_count_changed broadcast failed for vc %s",
            channel_id,
        )
