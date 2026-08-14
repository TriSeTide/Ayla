"""语音可见性契约测试（S1）：列表过滤 / 详情 403 / join 403 / 创建约束 / 序列化输出。

存量行为回归由 test_channel_api.py 覆盖（创建不传 visibility/group → 默认 public）。
"""
import pytest

from apps.common.visibility import Visibility
from apps.chat.models import Conversation, ConversationMember
from apps.voice.models import VoiceChannel


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


def _make_channel(owner, room_name, **kwargs):
    kwargs.setdefault("name", "可见性语音房")
    return VoiceChannel.objects.create(owner=owner, room_name=room_name, **kwargs)


# ---------- 列表过滤 ----------

@pytest.mark.django_db
def test_list_filters_by_visibility(auth_client, user_factory):
    """列表只返回可见语音房：public 全可见；friends 仅 owner+好友；group 仅群员。"""
    client, viewer = auth_client()
    owner = user_factory(username="owner")
    friend = user_factory(username="friend")
    stranger = user_factory(username="stranger")
    member = user_factory(username="member")
    _make_friends(owner, friend)
    group = _make_group(owner, member)

    _make_channel(owner, "room_pub", name="pub", visibility=Visibility.PUBLIC)
    _make_channel(owner, "room_fri", name="fri", visibility=Visibility.FRIENDS)
    _make_channel(owner, "room_grp", name="grp", visibility=Visibility.GROUP, group=group)

    resp = client.get("/api/v1/voice/channels/")
    names = {c["name"] for c in resp.json()}
    assert names == {"pub"}

    _make_friends(viewer, owner)
    resp = client.get("/api/v1/voice/channels/")
    names = {c["name"] for c in resp.json()}
    assert names == {"pub", "fri"}

    ConversationMember.objects.create(conversation=group, user=viewer)
    resp = client.get("/api/v1/voice/channels/")
    names = {c["name"] for c in resp.json()}
    assert names == {"pub", "fri", "grp"}


# ---------- 详情 / join 403 ----------

@pytest.mark.django_db
def test_detail_and_join_forbidden_for_invisible(auth_client, user_factory):
    """friends/group 语音房：路人 get 详情 / join → 403 带可读错误。"""
    client, _ = auth_client()
    owner = user_factory(username="owner")
    group = _make_group(owner)
    for vis, room, kw in (
        (Visibility.FRIENDS, "room_f_detail", {}),
        (Visibility.GROUP, "room_g_detail", {"group": group}),
    ):
        ch = _make_channel(owner, room, visibility=vis, **kw)
        resp = client.get(f"/api/v1/voice/channels/{ch.id}/")
        assert resp.status_code == 403, resp.content
        assert "无权" in resp.json()["detail"]
        resp = client.post(f"/api/v1/voice/channels/{ch.id}/join/")
        assert resp.status_code == 403, resp.content
        assert "无权" in resp.json()["detail"]


@pytest.mark.django_db
def test_join_ok_for_visible_public(auth_client, user_factory, monkeypatch):
    """public 语音房：路人 join → 200（存量行为不回退；token 走 mock）。"""
    client, _ = auth_client()
    owner = user_factory(username="owner")
    ch = _make_channel(owner, "room_pub_join", visibility=Visibility.PUBLIC)
    monkeypatch.setattr("apps.voice.views.livekit.issue_token", lambda u, r: "t")
    monkeypatch.setattr("apps.voice.views.settings.LIVEKIT_WS_URL", "ws://x")
    monkeypatch.setattr("apps.voice.views.settings.LIVEKIT_TOKEN_TTL_SECONDS", 600)

    resp = client.post(f"/api/v1/voice/channels/{ch.id}/join/")
    assert resp.status_code == 200, resp.content
    assert resp.json()["token"] == "t"


# ---------- 创建约束与序列化 ----------

@pytest.mark.django_db
def test_create_with_group_defaults_to_group_visibility(auth_client, user_factory):
    """创建带 group 不传 visibility → visibility=group，输出 group/group_name。"""
    client, user = auth_client()
    group_owner = user_factory(username="group_owner")
    group = _make_group(group_owner)
    ConversationMember.objects.create(conversation=group, user=user, role="member")

    resp = client.post(
        "/api/v1/voice/channels/",
        {"name": "群语音房", "group": str(group.id)},
        format="json",
    )
    assert resp.status_code == 201, resp.content
    data = resp.json()
    assert data["visibility"] == Visibility.GROUP
    assert data["group"] == str(group.id)
    assert data["group_name"] == "测试群"


@pytest.mark.django_db
def test_create_visibility_group_requires_group(auth_client):
    """visibility=group 不带 group → 400。"""
    client, _ = auth_client()
    resp = client.post(
        "/api/v1/voice/channels/",
        {"name": "x", "visibility": Visibility.GROUP},
        format="json",
    )
    assert resp.status_code == 400
    assert "群" in resp.json()["detail"]


@pytest.mark.django_db
def test_create_default_visibility_public(auth_client):
    """不传 visibility/group → 默认 public。"""
    client, _ = auth_client()
    resp = client.post("/api/v1/voice/channels/", {"name": "默认公开"}, format="json")
    assert resp.status_code == 201
    data = resp.json()
    assert data["visibility"] == Visibility.PUBLIC
    assert data["group"] is None
    assert data["group_name"] is None


@pytest.mark.django_db
def test_serializer_exposes_visibility_fields(auth_client):
    """列表/详情输出含 visibility/group/group_name 字段。"""
    client, user = auth_client()
    ch = _make_channel(user, "room_fields")
    resp = client.get("/api/v1/voice/channels/")
    item = resp.json()[0]
    assert "visibility" in item and "group" in item and "group_name" in item
    resp = client.get(f"/api/v1/voice/channels/{ch.id}/")
    assert resp.json()["visibility"] == Visibility.PUBLIC
