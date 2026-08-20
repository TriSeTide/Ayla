"""
可见性与准入 —— 全站统一（开发文档 §1.1，S1）。

- `Visibility`：live/voice/post/boardgame 房间/内容共用的可见性枚举；
- `visible_queryset(model, user)`：列表接口统一过滤（避免各 app 各写一套 Q 表达式）；
- `can_view(user, obj)` / `can_join(user, obj)`：单对象查看/进入校验（视图层返回 403）。

语义（工程约束，AGENTS.md §2.2：权限判断属于工程硬约束，必须实现）：
- `public`  → 任何登录用户可见/可进入；
- `friends` → owner 本人或其 accepted 好友；
- `group`   → 群成员可见；`group` 非空时默认 `group` 可见（创建时由 services 层落值）。
- `allowed_groups` 是独立的准入维度：白名单群成员始终可看，与 visibility 值无关
  （支持"好友+群"组合可见性场景：满足好友或群成员任一条件即可）。

注意：
- 好友/群成员集合用延迟导入（common 被 live/voice 引用，chat/accounts 不依赖 common，避免环）；
- `Q(group__in=my_groups)` 不带 visibility 条件：房间挂到某群后，群成员对该房间始终可见
  （与"group 非空时默认 group 可见"一致；显式覆盖为 friends/public 时群员仍可见，是放宽而非泄漏）。
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
        | Q(group_id__in=group_ids)
        | Q(allowed_groups__id__in=group_ids)
    ).distinct()


def can_view(user, obj) -> bool:
    """当前用户能否查看该对象（详情/内容/历史）。

    准入维度独立叠加：满足任一即可查看。
    - owner / public → 直接放行
    - visibility=friends → 好友可看
    - visibility=group → 群成员可看（group FK 或 allowed_groups 白名单）
    - allowed_groups 非空且包含用户所在群 → 无论 visibility 值，群成员可看
      （支持"好友+群"组合可见性场景）
    """
    if user is None or not user.is_authenticated:
        return False
    if obj.owner_id == user.id:
        return True
    if obj.visibility == Visibility.PUBLIC:
        return True
    # allowed_groups 是独立的准入维度：白名单群成员始终可看（覆盖 friends+group 组合场景）
    allowed_groups = getattr(obj, "allowed_groups", None)
    group_ids = None  # 延迟查询，按需获取
    if allowed_groups is not None:
        group_ids = _my_group_ids(user)
        if allowed_groups.filter(id__in=group_ids).exists():
            return True
    if obj.visibility == Visibility.FRIENDS:
        return obj.owner_id in _my_friend_ids(user)
    if obj.visibility == Visibility.GROUP:
        # 兼容旧的单群归属
        if group_ids is None:
            group_ids = _my_group_ids(user)
        return bool(obj.group_id and obj.group_id in group_ids)
    return False


def set_allowed_groups(obj, group_ids) -> None:
    """将群白名单写入可见性对象，校验目标均为群聊会话。"""
    from apps.chat.models import Conversation

    if group_ids is None:
        return
    if not isinstance(group_ids, list):
        raise ValueError("allowed_group_ids 必须是数组")
    groups = list(
        Conversation.objects.filter(
            id__in=[str(item) for item in group_ids], type=Conversation.TYPE_GROUP
        )
    )
    if len(groups) != len(set(str(item) for item in group_ids)):
        raise ValueError("allowed_group_ids 包含不存在或非群聊会话")
    obj.allowed_groups.set(groups)


def can_join(user, obj) -> bool:
    """当前用户能否进入/加入该对象（直播间发弹幕、语音房 join）。

    目前语义与 can_view 一致（无"只读房间"概念），保留独立函数供后续
    加入/进入比查看更严格的场景扩展。
    """
    return can_view(user, obj)
