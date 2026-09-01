"""
收藏领域服务（S6）。

跨类型 target 校验 + 收藏/取消：
- `validate_target(user, target_type, target_id)`：校验 target_type 合法、目标存在、
  且当前用户可见；返回目标对象，否则抛 ValueError（视图捕获转 400/404）。
- `add_favorite` / `remove_favorite`：收藏（幂等）/ 取消（仅本人）。

硬约束（AGENTS.md §2.2）：
- 权限判断（可见性、仅本人取消）是工程硬约束，必须实现；
- 收藏幂等靠 DB 唯一约束兜底 + get_or_create 语义。
"""
from .models import Favorite


def _coerce_id(target_id) -> str:
    """target_id 统一存字符串；None/空 → 抛 ValueError（视图层转 400）。"""
    if target_id is None or str(target_id).strip() == "":
        raise ValueError("target_id 不能为空")
    return str(target_id).strip()


def load_target(target_type: str, target_id: str):
    """按 target_type 读取目标对象（不做可见性校验；目标不存在返回 None）。"""
    if target_type == Favorite.TARGET_POST:
        from apps.posts.models import Post

        try:
            return Post.objects.filter(pk=int(target_id)).first()
        except (TypeError, ValueError):
            return None
    if target_type == Favorite.TARGET_MESSAGE:
        from apps.chat.models import Message

        try:
            return Message.objects.select_related("conversation").filter(pk=int(target_id)).first()
        except (TypeError, ValueError):
            return None
    if target_type == Favorite.TARGET_LIVE:
        from apps.live.models import LiveChannel

        try:
            return LiveChannel.objects.filter(pk=int(target_id)).first()
        except (TypeError, ValueError):
            return None
    if target_type == Favorite.TARGET_VOICE:
        from apps.voice.models import VoiceChannel

        try:
            return VoiceChannel.objects.filter(pk=int(target_id)).first()
        except (TypeError, ValueError):
            return None
    if target_type == Favorite.TARGET_GAME:
        from apps.boardgame.models import GameRoom

        try:
            return GameRoom.objects.filter(pk=int(target_id)).first()
        except (TypeError, ValueError):
            return None
    if target_type == Favorite.TARGET_GROUP:
        from apps.chat.models import Conversation

        try:
            return Conversation.objects.filter(
                pk=int(target_id), type=Conversation.TYPE_GROUP
            ).first()
        except (TypeError, ValueError):
            return None
    return None


def validate_target(user, target_type: str, target_id: str):
    """校验收藏目标：返回目标对象；非法/不存在/不可见 → 抛 ValueError。

    - target_type 必须在 TARGET_CHOICES 内；
    - 目标必须存在（post/live/voice/game 还需当前用户 can_view）；
    - group：Conversation 无 visibility 字段，存在即可（成员与非成员都能收藏群）。
    """
    valid_types = {choice[0] for choice in Favorite.TARGET_CHOICES}
    if target_type not in valid_types:
        raise ValueError("target_type 非法")

    target_id = _coerce_id(target_id)

    if target_type == Favorite.TARGET_GROUP:
        from apps.chat.models import Conversation

        try:
            conv = Conversation.objects.filter(
                pk=int(target_id), type=Conversation.TYPE_GROUP
            ).first()
        except (TypeError, ValueError):
            conv = None
        if conv is None:
            raise ValueError("目标不存在")
        return conv

    target = load_target(target_type, target_id)
    if target is None:
        raise ValueError("目标不存在")

    if target_type == Favorite.TARGET_MESSAGE:
        from apps.chat.models import ConversationMember

        if not ConversationMember.objects.filter(
            conversation_id=target.conversation_id, user=user
        ).exists():
            raise PermissionError("无权收藏该目标")
        return target

    from apps.common.visibility import can_view

    if not can_view(user, target):
        raise PermissionError("无权收藏该目标")

    return target


def add_favorite(user, target_type: str, target_id: str):
    """收藏（幂等）：返回 (Favorite, created)。"""
    favorite, created = Favorite.objects.get_or_create(
        user=user, target_type=target_type, target_id=target_id
    )
    return favorite, created


def remove_favorite(user, favorite: Favorite) -> None:
    """取消收藏：仅本人可取消，否则抛 PermissionError。"""
    if favorite.user_id != user.id:
        raise PermissionError("仅本人可取消收藏")
    favorite.delete()


# ---------- 收藏 WS 广播（任务 07：收藏/取消后各界面实时同步） ----------
#
# 收藏是用户私有数据（favorites 表按 user 过滤），因此只推给收藏者本人：
# 走 `chat_user_<user_id>` 用户级组（ChatConsumer connect 时已加入），
# 同账号所有界面（帖子卡片/详情、直播/语音/桌游/群卡片、收藏页）实时同步；
# 其他用户不感知他人收藏，符合收藏私有语义。

def _favorite_changed_event(target_type: str, target_id: str, favorite_id: int, action: str) -> dict:
    """favorite.changed 事件载荷（group_send 用）。"""
    return {
        "type": "favorite.changed",
        "data": {
            "target_type": target_type,
            "target_id": str(target_id),
            "favorite_id": favorite_id,
            "action": action,
        },
    }


def broadcast_favorite_changed(user_id, target_type: str, target_id: str, favorite_id: int, action: str) -> None:
    """收藏/取消收藏 → 推给收藏者本人（同步版，REST 视图线程上下文）。

    - action="added"：收藏成功（favorite_id 为新收藏 id）；
    - action="removed"：取消收藏（favorite_id 为被删除的收藏 id）。
    复用 chat 的用户级广播（捕获 ChannelFull 记 warning，不阻塞收藏请求）。
    """
    from apps.chat.services import _user_group_send_sync

    _user_group_send_sync(
        user_id,
        _favorite_changed_event(target_type, target_id, favorite_id, action),
    )
