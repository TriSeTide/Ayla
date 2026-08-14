"""直播可见性契约测试（S1）：列表过滤 / 详情 403 / 弹幕 403 / 创建约束 / 序列化输出。

存量行为回归由 test_live_api.py 覆盖（创建不传 visibility/group → 默认 public）。
"""
import pytest

from apps.common.visibility import Visibility
from apps.chat.models import Conversation, ConversationMember
from apps.live.models import LiveChannel


def _make_group(owner, user=None):
    conv = Conversation.objects.create(type="group", title="测试群", owner=owner)
    ConversationMember.objects.create(conversation=conv, user=owner, role="owner")
    if user is not None:
        ConversationMember.objects.create(conversation=conv, user=user)
    return conv


def _make_friends(a, b):
    from apps.accounts.models import Friendship

    Friendship.objects.create(user=a, friend=b, status="accepted")
    Friendship.objects.create(user=b, friend=a, status="accepted")


def _make_channel(owner, **kwargs):
    from apps.live.services import gen_stream_key

    kwargs.setdefault("title", "可见性直播间")
    kwargs.setdefault("stream_key", gen_stream_key())
    return LiveChannel.objects.create(owner=owner, **kwargs)


# ---------- 列表过滤 ----------

@pytest.mark.django_db
def test_list_filters_by_visibility(auth_client, user_factory):
    """列表只返回可见房间：public 全可见；friends 仅 owner+好友；group 仅群员。"""
    client, viewer = auth_client()
    owner = user_factory(username="owner")
    friend = user_factory(username="friend")
    stranger = user_factory(username="stranger")
    member = user_factory(username="member")
    _make_friends(owner, friend)
    group = _make_group(owner, member)

    _make_channel(owner, title="pub", visibility=Visibility.PUBLIC)
    _make_channel(owner, title="fri", visibility=Visibility.FRIENDS)
    _make_channel(owner, title="grp", visibility=Visibility.GROUP, group=group)

    resp = client.get("/api/v1/live/channels/")
    assert resp.status_code == 200
    titles = {c["title"] for c in resp.json()}
    assert titles == {"pub"}  # viewer 与 owner 无任何关系

    # viewer 是 owner 的好友 → 多看到 friends 房间
    _make_friends(viewer, owner)
    resp = client.get("/api/v1/live/channels/")
    titles = {c["title"] for c in resp.json()}
    assert titles == {"pub", "fri"}

    # viewer 加入群 → 看到 group 房间
    ConversationMember.objects.create(conversation=group, user=viewer)
    resp = client.get("/api/v1/live/channels/")
    titles = {c["title"] for c in resp.json()}
    assert titles == {"pub", "fri", "grp"}


@pytest.mark.django_db
def test_list_only_live_still_filters(auth_client, user_factory):
    """?only_live=1 与可见性过滤叠加（群组房间 + live 状态）。"""
    client, viewer = auth_client()
    owner = user_factory(username="owner")
    group = _make_group(owner, viewer)
    live_ch = _make_channel(owner, title="live-grp", visibility=Visibility.GROUP, group=group)
    live_ch.status = "live"
    live_ch.save(update_fields=["status"])
    _make_channel(owner, title="idle-grp", visibility=Visibility.GROUP, group=group)

    resp = client.get("/api/v1/live/channels/?only_live=1")
    titles = {c["title"] for c in resp.json()}
    assert titles == {"live-grp"}


# ---------- 详情 / 弹幕 403 ----------

@pytest.mark.django_db
def test_detail_forbidden_for_invisible(auth_client, user_factory):
    """friends/group 房间：路人 get 详情 → 403 带可读错误。"""
    client, _ = auth_client()
    owner = user_factory(username="owner")
    group = _make_group(owner)
    for vis, kw in (
        (Visibility.FRIENDS, {}),
        (Visibility.GROUP, {"group": group}),
    ):
        ch = _make_channel(owner, visibility=vis, **kw)
        resp = client.get(f"/api/v1/live/channels/{ch.id}/")
        assert resp.status_code == 403, resp.content
        assert "无权" in resp.json()["detail"]

    # owner 详情可见
    from rest_framework.test import APIClient
    from rest_framework_simplejwt.tokens import RefreshToken

    owner_client = APIClient()
    owner_client.credentials(
        HTTP_AUTHORIZATION=f"Bearer {RefreshToken.for_user(owner).access_token}"
    )
    resp = owner_client.get(f"/api/v1/live/channels/{_make_channel(owner, visibility=Visibility.GROUP, group=group).id}/")
    assert resp.status_code == 200


@pytest.mark.django_db
def test_danmaku_forbidden_for_invisible(auth_client, user_factory):
    """friends 房间：路人发弹幕/看弹幕 → 403（进入互动需 can_join）。"""
    client, _ = auth_client()
    owner = user_factory(username="owner")
    ch = _make_channel(owner, visibility=Visibility.FRIENDS)

    resp = client.post(
        f"/api/v1/live/channels/{ch.id}/danmaku/", {"content": "hi"}, format="json"
    )
    assert resp.status_code == 403
    resp = client.get(f"/api/v1/live/channels/{ch.id}/danmaku/")
    assert resp.status_code == 403
    resp = client.get(f"/api/v1/live/channels/{ch.id}/status/")
    assert resp.status_code == 403


@pytest.mark.django_db
def test_public_channel_danmaku_still_works(auth_client, user_factory):
    """public 房间：路人可看弹幕/发弹幕（存量行为不回退）。"""
    client, _ = auth_client()
    owner = user_factory(username="owner")
    ch = _make_channel(owner, visibility=Visibility.PUBLIC)

    resp = client.post(
        f"/api/v1/live/channels/{ch.id}/danmaku/", {"content": "你好"}, format="json"
    )
    assert resp.status_code == 201, resp.content
    resp = client.get(f"/api/v1/live/channels/{ch.id}/danmaku/")
    assert resp.status_code == 200


# ---------- 创建约束与序列化 ----------

@pytest.mark.django_db
def test_create_with_group_defaults_to_group_visibility(auth_client, user_factory):
    """创建带 group 不传 visibility → visibility=group，输出 group/group_name。"""
    client, user = auth_client()
    owner = user_factory(username="group_owner")
    group = _make_group(owner)
    ConversationMember.objects.create(conversation=group, user=user, role="member")

    resp = client.post(
        "/api/v1/live/channels/",
        {"title": "群直播间", "group": str(group.id)},
        format="json",
    )
    assert resp.status_code == 201, resp.content
    data = resp.json()
    assert data["visibility"] == Visibility.GROUP
    assert data["group"] == str(group.id)
    assert data["group_name"] == "测试群"


@pytest.mark.django_db
def test_create_visibility_group_requires_group(auth_client):
    """visibility=group 不带 group → 400 可读错误。"""
    client, _ = auth_client()
    resp = client.post(
        "/api/v1/live/channels/",
        {"title": "x", "visibility": Visibility.GROUP},
        format="json",
    )
    assert resp.status_code == 400
    assert "群" in resp.json()["detail"]


@pytest.mark.django_db
def test_create_group_must_be_group_conversation(auth_client, user_factory):
    """group 指向私聊会话 → 400。"""
    client, user = auth_client()
    peer = user_factory(username="peer")
    conv = Conversation.objects.create(type="private", owner=user)
    ConversationMember.objects.create(conversation=conv, user=user)
    ConversationMember.objects.create(conversation=conv, user=peer)

    resp = client.post(
        "/api/v1/live/channels/",
        {"title": "x", "group": str(conv.id), "visibility": Visibility.GROUP},
        format="json",
    )
    assert resp.status_code == 400
    assert "群" in resp.json()["detail"]


@pytest.mark.django_db
def test_create_default_visibility_public(auth_client):
    """不传 visibility/group → 默认 public（存量行为不变）。"""
    client, _ = auth_client()
    resp = client.post("/api/v1/live/channels/", {"title": "默认公开"}, format="json")
    assert resp.status_code == 201
    data = resp.json()
    assert data["visibility"] == Visibility.PUBLIC
    assert data["group"] is None
    assert data["group_name"] is None


@pytest.mark.django_db
def test_serializer_exposes_visibility_fields(auth_client, live_channel_factory):
    """列表/详情输出含 visibility/group/group_name 字段。"""
    client, user = auth_client()
    ch = live_channel_factory(owner=user)
    resp = client.get("/api/v1/live/channels/")
    item = resp.json()[0]
    assert "visibility" in item and "group" in item and "group_name" in item
    resp = client.get(f"/api/v1/live/channels/{ch.id}/")
    assert resp.json()["visibility"] == Visibility.PUBLIC
