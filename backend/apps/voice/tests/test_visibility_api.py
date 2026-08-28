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
    group = kwargs.get("group")
    ch = VoiceChannel.objects.create(owner=owner, room_name=room_name, **kwargs)
    # 群可见性由 allowed_groups 白名单提供（group FK 不承载可见性），模拟 services 兜底。
    if group is not None and kwargs.get("visibility") == Visibility.GROUP:
        from apps.common.visibility import set_allowed_groups
        set_allowed_groups(ch, [str(group.id)])
    return ch


def _client_for(user):
    """为已存在用户签发 JWT 客户端（auth_client 会新建用户，不适合复用）。"""
    from rest_framework.test import APIClient
    from rest_framework_simplejwt.tokens import RefreshToken

    client = APIClient()
    client.credentials(
        HTTP_AUTHORIZATION=f"Bearer {RefreshToken.for_user(user).access_token}"
    )
    return client


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
def test_create_visibility_group_without_group_or_whitelist_rejected(auth_client):
    """visibility=group 且无 group 归属、无群白名单 → 400（避免建出对所有人不可见的房间）。"""
    client, _ = auth_client()
    resp = client.post(
        "/api/v1/voice/channels/",
        {"name": "x", "visibility": Visibility.GROUP},
        format="json",
    )
    assert resp.status_code == 400
    assert "至少选择一个群" in resp.json()["detail"]


@pytest.mark.django_db
def test_create_group_visible_room_from_global_with_allowed_groups(auth_client, user_factory):
    """全局列表创建"指定群可见"语音房：visibility=group + allowed_group_ids（多群）→ 201。"""
    client, owner = auth_client()
    group1 = _make_group(owner)
    group2 = _make_group(owner)

    resp = client.post(
        "/api/v1/voice/channels/",
        {
            "name": "多群可见语音房",
            "visibility": Visibility.GROUP,
            "allowed_group_ids": [str(group1.id), str(group2.id)],
        },
        format="json",
    )
    assert resp.status_code == 201, resp.content
    data = resp.json()
    assert data["visibility"] == Visibility.GROUP
    assert data["group"] is None
    assert set(data["allowed_group_ids"]) == {str(group1.id), str(group2.id)}


@pytest.mark.django_db
def test_group_visible_room_visibility_by_whitelist(auth_client, user_factory):
    """白名单群成员可见（列表+详情），非成员不可见；owner 始终可见。"""
    client, owner = auth_client()
    group1 = _make_group(owner)
    group2 = _make_group(owner)
    member1 = user_factory(username="g1_member")
    member2 = user_factory(username="g2_member")
    stranger = user_factory(username="stranger")
    ConversationMember.objects.create(conversation=group1, user=member1)
    ConversationMember.objects.create(conversation=group2, user=member2)

    resp = client.post(
        "/api/v1/voice/channels/",
        {
            "name": "白名单语音房",
            "visibility": Visibility.GROUP,
            "allowed_group_ids": [str(group1.id), str(group2.id)],
        },
        format="json",
    )
    assert resp.status_code == 201, resp.content
    channel_id = resp.json()["id"]

    def _names_for(http_client):
        return {c["name"] for c in http_client.get("/api/v1/voice/channels/").json()}

    # owner 始终可见
    assert "白名单语音房" in _names_for(client)
    # 群1/群2 成员：列表可见 + 详情 200
    for member in (member1, member2):
        c = _client_for(member)
        assert "白名单语音房" in _names_for(c)
        assert c.get(f"/api/v1/voice/channels/{channel_id}/").status_code == 200
    # 非成员：列表不可见 + 详情 403
    c = _client_for(stranger)
    assert "白名单语音房" not in _names_for(c)
    assert c.get(f"/api/v1/voice/channels/{channel_id}/").status_code == 403


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


# ---------- PATCH 可见性（与创建同约束：group 可见需有群归属或白名单） ----------

@pytest.mark.django_db
def test_patch_visibility_group_without_group_or_whitelist_rejected(auth_client, user_factory):
    """无群归属的 public 房 patch 成 group 可见且无白名单 → 400（避免改出对所有人不可见的房间）。"""
    client, owner = auth_client()
    ch = _make_channel(owner, "room_patch_g")

    resp = client.patch(
        f"/api/v1/voice/channels/{ch.id}/",
        {"name": ch.name, "visibility": Visibility.GROUP},
        format="json",
    )
    assert resp.status_code == 400, resp.content
    assert "至少选择一个群" in resp.json()["detail"]
    # 未生效：仍是 public
    assert VoiceChannel.objects.get(pk=ch.id).visibility == Visibility.PUBLIC


@pytest.mark.django_db
def test_patch_visibility_group_with_whitelist_ok(auth_client, user_factory):
    """无群归属房 patch 成 group 可见 + 白名单 → 200，白名单落库且成员可见。"""
    client, owner = auth_client()
    group = _make_group(owner)
    member = user_factory(username="patch_member")
    ConversationMember.objects.create(conversation=group, user=member)
    ch = _make_channel(owner, "room_patch_g2")

    resp = client.patch(
        f"/api/v1/voice/channels/{ch.id}/",
        {
            "name": ch.name,
            "visibility": Visibility.GROUP,
            "allowed_group_ids": [str(group.id)],
        },
        format="json",
    )
    assert resp.status_code == 200, resp.content
    data = resp.json()
    assert data["visibility"] == Visibility.GROUP
    assert data["allowed_group_ids"] == [str(group.id)]

    ch.refresh_from_db()
    assert list(ch.allowed_groups.values_list("id", flat=True)) == [group.id]
    c = _client_for(member)
    assert c.get(f"/api/v1/voice/channels/{ch.id}/").status_code == 200
