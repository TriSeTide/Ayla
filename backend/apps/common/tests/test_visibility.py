"""apps/common 契约测试 —— 可见性 helper 矩阵（S1，开发文档 §1.1）。

覆盖 public/friends/group × owner/好友/群员/路人 的可见性矩阵：
- 以 LiveChannel 作为同构模型代表（live/voice/post/boardgame 字段一致，helper 通用）；
- `visible_queryset` 列表过滤与 `can_view`/`can_join` 单对象校验语义一致。
"""
import pytest

from apps.common.visibility import Visibility, can_join, can_view, visible_queryset
from apps.live.models import LiveChannel
from apps.live.services import gen_stream_key


def _make_channel(owner, **kwargs) -> LiveChannel:
    kwargs.setdefault("title", "可见性测试直播间")
    kwargs.setdefault("stream_key", gen_stream_key())
    return LiveChannel.objects.create(owner=owner, **kwargs)


def _make_group(group_owner, user):
    """建群并把人拉进群（owner=group_owner，成员=user）。"""
    from apps.chat.models import Conversation, ConversationMember

    conv = Conversation.objects.create(
        type=Conversation.TYPE_GROUP, title="测试群", owner=group_owner
    )
    ConversationMember.objects.create(conversation=conv, user=group_owner, role="owner")
    ConversationMember.objects.create(conversation=conv, user=user)
    return conv


def _make_friends(a, b):
    """a/b 互为 accepted 好友（Friendship 双向两条记录）。"""
    from apps.accounts.models import Friendship

    Friendship.objects.create(user=a, friend=b, status=Friendship.STATUS_ACCEPTED)
    Friendship.objects.create(user=b, friend=a, status=Friendship.STATUS_ACCEPTED)


# ---------- public ----------

@pytest.mark.django_db
def test_public_visible_to_all_logged_in(user_factory):
    """public 房间：owner/好友/群员/路人 全部可见（任何登录用户）。"""
    owner = user_factory(username="owner")
    friend = user_factory(username="friend")
    stranger = user_factory(username="stranger")
    member = user_factory(username="member")
    _make_friends(owner, friend)
    group = _make_group(owner, member)

    ch = _make_channel(owner, visibility=Visibility.PUBLIC)

    for user in (owner, friend, member, stranger):
        assert can_view(user, ch), f"{user.username} 应可见 public 房间"
        assert can_join(user, ch), f"{user.username} 应可进入 public 房间"
        assert ch in visible_queryset(LiveChannel, user), f"{user.username} 列表应含 public 房间"

    # 群归属房间对群员也可见（Q(group__in=my_groups) 分支，开发文档 §1.1 公式）
    ch2 = _make_channel(owner, visibility=Visibility.PUBLIC, group=group)
    assert ch2 in visible_queryset(LiveChannel, member)


# ---------- friends ----------

@pytest.mark.django_db
def test_friends_visible_to_owner_and_friends(user_factory):
    """friends 房间：owner 本人 + accepted 好友可见；路人（含非好友）不可见。"""
    owner = user_factory(username="owner")
    friend = user_factory(username="friend")
    stranger = user_factory(username="stranger")
    _make_friends(owner, friend)

    ch = _make_channel(owner, visibility=Visibility.FRIENDS)

    assert can_view(owner, ch)
    assert can_view(friend, ch)
    assert not can_view(stranger, ch)
    assert not can_join(stranger, ch)
    assert ch in visible_queryset(LiveChannel, owner)
    assert ch in visible_queryset(LiveChannel, friend)
    assert ch not in visible_queryset(LiveChannel, stranger)


@pytest.mark.django_db
def test_friends_visibility_is_directional(user_factory):
    """friends 可见性只认 owner 的 accepted 好友：单向 pending 不算。"""
    owner = user_factory(username="owner")
    pending_user = user_factory(username="pending_user")

    # 只有 pending 关系（未确认）
    from apps.accounts.models import Friendship

    Friendship.objects.create(user=pending_user, friend=owner, status="pending")

    ch = _make_channel(owner, visibility=Visibility.FRIENDS)
    assert not can_view(pending_user, ch)
    assert ch not in visible_queryset(LiveChannel, pending_user)


# ---------- group ----------

@pytest.mark.django_db
def test_group_visible_to_members_only(user_factory):
    """group 房间：owner 可见（owner 分支）+ 群员可见；路人/非群员好友不可见。"""
    owner = user_factory(username="owner")
    member = user_factory(username="member")
    friend_not_member = user_factory(username="friend_not_member")
    stranger = user_factory(username="stranger")
    _make_friends(owner, friend_not_member)
    group = _make_group(owner, member)

    ch = _make_channel(owner, visibility=Visibility.GROUP, group=group)

    assert can_view(owner, ch)
    assert can_view(member, ch)
    # 好友但不是群员 → 不可见（friends 分支不覆盖 group 房间）
    assert not can_view(friend_not_member, ch)
    assert not can_view(stranger, ch)
    assert ch in visible_queryset(LiveChannel, owner)
    assert ch in visible_queryset(LiveChannel, member)
    assert ch not in visible_queryset(LiveChannel, friend_not_member)
    assert ch not in visible_queryset(LiveChannel, stranger)


@pytest.mark.django_db
def test_group_visibility_without_group_is_invisible_to_others(user_factory):
    """visibility=group 但 group 为空（数据异常）：仅 owner 可见，他人不可见。"""
    owner = user_factory(username="owner")
    stranger = user_factory(username="stranger")
    ch = _make_channel(owner, visibility=Visibility.GROUP)

    assert can_view(owner, ch)
    assert not can_view(stranger, ch)
    assert ch not in visible_queryset(LiveChannel, stranger)


# ---------- 未登录 / 列表聚合 ----------

@pytest.mark.django_db
def test_unauthenticated_sees_nothing(user_factory):
    """未登录：visible_queryset 空、can_view/can_join False（安全默认）。"""
    owner = user_factory(username="owner")
    _make_channel(owner, visibility=Visibility.PUBLIC)

    qs = visible_queryset(LiveChannel, None)
    assert qs.count() == 0
    assert list(qs) == []

    anon = type("Anon", (), {"is_authenticated": False})()
    assert not can_view(anon, _make_channel(owner))
    assert not can_join(anon, _make_channel(owner))


@pytest.mark.django_db
def test_visible_queryset_mixed_filter(user_factory):
    """混合场景：列表只返回该用户可见的（public + 我的 + 好友 + 我所在群）。"""
    owner = user_factory(username="owner")
    friend = user_factory(username="friend")
    stranger = user_factory(username="stranger")
    member = user_factory(username="member")
    _make_friends(owner, friend)
    group = _make_group(owner, member)

    _make_channel(owner, title="public", visibility=Visibility.PUBLIC)
    _make_channel(owner, title="friends", visibility=Visibility.FRIENDS)
    _make_channel(owner, title="grouped", visibility=Visibility.GROUP, group=group)

    ids = set(visible_queryset(LiveChannel, member).values_list("id", flat=True))
    titles = set(LiveChannel.objects.filter(id__in=ids).values_list("title", flat=True))
    # member 可见：public + 自己所在群的 group 房间（friends 房间不可见）
    assert titles == {"public", "grouped"}

    ids = set(visible_queryset(LiveChannel, friend).values_list("id", flat=True))
    titles = set(LiveChannel.objects.filter(id__in=ids).values_list("title", flat=True))
    assert titles == {"public", "friends"}

    ids = set(visible_queryset(LiveChannel, stranger).values_list("id", flat=True))
    titles = set(LiveChannel.objects.filter(id__in=ids).values_list("title", flat=True))
    assert titles == {"public"}


@pytest.mark.django_db
def test_can_join_matches_can_view(user_factory):
    """can_join 当前语义与 can_view 一致（无"只读房间"，保留独立接口）。"""
    owner = user_factory(username="owner")
    stranger = user_factory(username="stranger")
    for vis in (Visibility.PUBLIC, Visibility.FRIENDS, Visibility.GROUP):
        ch = _make_channel(owner, visibility=vis)
        assert can_join(owner, ch) == can_view(owner, ch)
        assert can_join(stranger, ch) == can_view(stranger, ch)


# ---------- 好友+群 组合可见性 ----------

@pytest.mark.django_db
def test_friends_plus_allowed_groups_group_member_can_view(user_factory):
    """visibility=friends + allowed_groups 非空：群成员（非好友）也能查看。

    场景：创建时同时勾选"好友可见"和"指定群可见"，群员在列表能看到条目，
    点进详情也应放行（之前只检查 friends 分支导致 403）。
    """
    owner = user_factory(username="owner")
    friend = user_factory(username="friend")
    member = user_factory(username="member")
    stranger = user_factory(username="stranger")
    _make_friends(owner, friend)
    group = _make_group(owner, member)

    ch = _make_channel(owner, visibility=Visibility.FRIENDS)
    # 模拟前端同时传 allowed_group_ids
    from apps.common.visibility import set_allowed_groups
    set_allowed_groups(ch, [str(group.id)])

    # owner 本人
    assert can_view(owner, ch)
    # 好友（非群员）→ 通过 friends 分支放行
    assert can_view(friend, ch)
    # 群成员（非好友）→ 通过 allowed_groups 分支放行
    assert can_view(member, ch)
    assert can_join(member, ch)
    # 路人（非好友非群员）→ 不可见
    assert not can_view(stranger, ch)
    # 列表过滤也应一致
    qs = visible_queryset(LiveChannel, member)
    assert ch in qs
    qs2 = visible_queryset(LiveChannel, stranger)
    assert ch not in qs2
