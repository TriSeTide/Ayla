"""
可见性与准入 —— 全站统一（开发文档 §1.1，S1）。

- `Visibility`：live/voice/post/boardgame 房间/内容共用的可见性枚举；
- `visible_queryset(model, user)`：列表接口统一过滤（避免各 app 各写一套 Q 表达式）；
- `can_view(user, obj)` / `can_join(user, obj)`：单对象查看/进入校验（视图层返回 403）。

语义（工程约束，AGENTS.md §2.2：权限判断属于工程硬约束，必须实现）：
- `public`  → 任何登录用户可见/可进入；
- `friends` → owner 本人或其 accepted 好友；
- `group`   → 仅白名单群成员可见（`allowed_groups` 非空）。
- `allowed_groups` 是**唯一**的群可见性维度：群成员是否可见完全由白名单决定，
  与 `group`（归属群 FK）无关；`group` 仅是来源/归属标记，不再承载可见性。
  支持"公开+群""好友+群"组合场景（满足公开/好友或白名单群成员任一条件即可）。

注意：
- 好友/群成员集合用延迟导入（common 被 live/voice 引用，chat/accounts 不依赖 common，避免环）；
- `group` FK 不再进入可见性判定：群可见性必须由 `allowed_groups` 显式表达
  （创建时 services 层把归属群落进白名单，见各 app services 的兜底）。
"""
from django.db import models
from django.db.models import Q


class Visibility(models.TextChoices):
    PUBLIC = "public", "公开"
    FRIENDS = "friends", "好友可见"
    GROUP = "group", "群成员可见"


def _my_friend_ids(user) -> list:
    """当前用户 accepted 好友 id 列表（Friendship 双向存储，单向查询足够）。"""
    from apps.accounts.models import Friendship

    return list(
        Friendship.objects.filter(user=user, status=Friendship.STATUS_ACCEPTED)
        .values_list("friend_id", flat=True)
    )


def _my_group_ids(user) -> list:
    """当前用户所在群（ConversationMember）id 列表。"""
    from apps.chat.models import ConversationMember

    return list(
        ConversationMember.objects.filter(user=user).values_list(
            "conversation_id", flat=True
        )
    )


def visible_queryset(model, user):
    """返回当前用户可见的对象 queryset（不触发查询）。

    `model` 需具备 `visibility`、`owner`、`group` 字段（live/voice/post/boardgame 同构）。
    """
    if user is None or not user.is_authenticated:
        return model.objects.none()
    friend_ids = _my_friend_ids(user)
    group_ids = _my_group_ids(user)
    return model.objects.filter(
        Q(visibility=Visibility.PUBLIC)
        | Q(owner_id=user.id)
        | (Q(visibility=Visibility.FRIENDS) & Q(owner_id__in=friend_ids))
        | Q(allowed_groups__id__in=group_ids)
    ).distinct()


def can_view(user, obj) -> bool:
    """当前用户能否查看该对象（详情/内容/历史）。

    准入维度独立叠加：满足任一即可查看。
    - owner / public → 直接放行
    - visibility=friends → 好友可看
    - allowed_groups 非空且包含用户所在群 → 群成员可看（无论 visibility 值，
      支持"公开+群""好友+群"组合场景）
    - visibility=group → 仅白名单群成员可看（allowed_groups 为空则无人可见，
      归属群 `group` FK 不提供可见性）
    """
    if user is None or not user.is_authenticated:
        return False
    if obj.owner_id == user.id:
        return True
    if obj.visibility == Visibility.PUBLIC:
        return True
    # allowed_groups 是唯一的群可见性维度：白名单群成员可看（覆盖任意 visibility
    # 与群白名单的组合场景）
    allowed_groups = getattr(obj, "allowed_groups", None)
    if allowed_groups is not None and allowed_groups.filter(
        id__in=_my_group_ids(user)
    ).exists():
        return True
    if obj.visibility == Visibility.FRIENDS:
        return obj.owner_id in _my_friend_ids(user)
    # visibility=group：可见性仅由 allowed_groups 提供（已在上面判断），无额外放行。
    return False


def set_allowed_groups(obj, group_ids) -> None:
    """将群白名单写入可见性对象，校验目标均为群聊会话。"""
    from apps.chat.models import Conversation

    if group_ids is None:
        return
    if not isinstance(group_ids, list):
        raise ValueError("allowed_group_ids 必须是数组")
    try:
        groups = list(
            Conversation.objects.filter(
                id__in=[str(item) for item in group_ids], type=Conversation.TYPE_GROUP
            )
        )
    except ValueError as exc:
        # 无效 id（如非 UUID 字符串）在查询期即抛 ValueError，统一归属到字段名
        raise ValueError(f"allowed_group_ids 包含无效的群 id（{exc}）") from exc
    if len(groups) != len(set(str(item) for item in group_ids)):
        raise ValueError("allowed_group_ids 包含不存在或非群聊会话")
    obj.allowed_groups.set(groups)


def can_join(user, obj) -> bool:
    """当前用户能否进入/加入该对象（直播间发弹幕、语音房 join）。

    目前语义与 can_view 一致（无"只读房间"概念），保留独立函数供后续
    加入/进入比查看更严格的场景扩展。
    """
    return can_view(user, obj)
