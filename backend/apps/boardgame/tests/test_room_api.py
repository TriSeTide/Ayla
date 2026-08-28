"""桌游室 REST 契约测试（S4，开发文档 §1.4）。

覆盖：房间 CRUD（创建默认公开/群归属默认群可见/可见性约束/多群白名单可见）、
列表可见性过滤、详情 403、删除仅 owner、join 幂等（重复 join 不重复建成员）、
join 可见性校验、leave 仅成员、seat 顺序分配、?mine=1 我在局。
"""
import pytest

from apps.common.visibility import Visibility
from apps.boardgame.models import GameRoom, GameRoomMember
from apps.chat.models import Conversation, ConversationMember


def _make_group(owner, users=None):
    conv = Conversation.objects.create(type="group", title="测试群", owner=owner)
    ConversationMember.objects.create(conversation=conv, user=owner, role="owner")
    for u in users or []:
        ConversationMember.objects.create(conversation=conv, user=u)
    return conv


def _make_friends(a, b):
    from apps.accounts.models import Friendship

    Friendship.objects.create(user=a, friend=b, status="accepted")
    Friendship.objects.create(user=b, friend=a, status="accepted")


def _make_room(owner, name="测试房", **kwargs):
    group = kwargs.get("group")
    room = GameRoom.objects.create(owner=owner, name=name, **kwargs)
    # 群可见性由 allowed_groups 白名单提供（group FK 不承载可见性），模拟 services 兜底。
    if group is not None and kwargs.get("visibility") == Visibility.GROUP:
        from apps.common.visibility import set_allowed_groups
        set_allowed_groups(room, [str(group.id)])
    return room


# ---------- 创建 ----------

@pytest.mark.django_db
class TestCreateRoom:
    def test_create_public_default(self, auth_client):
        client, user = auth_client(username="b_author")
        resp = client.post("/api/v1/boardgame/rooms/", {"name": "我的桌游室"}, format="json")
        assert resp.status_code == 201, resp.content
        data = resp.json()
        assert data["name"] == "我的桌游室"
        assert data["visibility"] == Visibility.PUBLIC
        assert data["group"] is None
        assert data["group_name"] is None
        assert data["owner_id"] == user.id
        assert data["is_owner"] is True
        assert data["game_type"] == "boardgame"
        assert data["status"] == "waiting"
        assert data["member_count"] == 0
        assert data["is_member"] is False

    def test_create_requires_name(self, auth_client):
        client, _ = auth_client(username="b_no_name")
        resp = client.post("/api/v1/boardgame/rooms/", {"name": "  "}, format="json")
        assert resp.status_code == 400

    def test_create_group_defaults_to_group_visibility(self, auth_client):
        client, user = auth_client(username="b_group_author")
        group = _make_group(user)
        resp = client.post(
            "/api/v1/boardgame/rooms/",
            {"name": "群内桌游室", "group": str(group.id)},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        data = resp.json()
        assert data["visibility"] == Visibility.GROUP
        assert data["group"] == str(group.id)
        assert data["group_name"] == "测试群"

    def test_create_group_visibility_requires_group_or_whitelist(self, auth_client):
        """Bug #10：group 可见但既无归属群也无白名单 → 400（校验后置到 create_room）。"""
        client, _ = auth_client(username="b_grp_vis")
        resp = client.post(
            "/api/v1/boardgame/rooms/",
            {"name": "x", "visibility": Visibility.GROUP},
            format="json",
        )
        assert resp.status_code == 400
        assert "至少选择一个群" in resp.json()["detail"]

    def test_create_group_visibility_empty_whitelist_400(self, auth_client):
        """空白名单数组（[]）视为未选群 → 400。"""
        client, _ = auth_client(username="b_grp_vis_empty")
        resp = client.post(
            "/api/v1/boardgame/rooms/",
            {"name": "x", "visibility": Visibility.GROUP, "allowed_group_ids": []},
            format="json",
        )
        assert resp.status_code == 400
        assert "至少选择一个群" in resp.json()["detail"]

    def test_create_group_whitelist_without_group(self, auth_client):
        """Bug #10：全局（不传 group）指定群可见 + 多群白名单 → 201，白名单落库。"""
        client, owner = auth_client(username="b_wl_owner")
        g1 = _make_group(owner)
        g2 = _make_group(owner)
        resp = client.post(
            "/api/v1/boardgame/rooms/",
            {
                "name": "白名单桌游室",
                "visibility": Visibility.GROUP,
                "allowed_group_ids": [str(g1.id), str(g2.id)],
            },
            format="json",
        )
        assert resp.status_code == 201, resp.content
        data = resp.json()
        assert data["visibility"] == Visibility.GROUP
        assert data["group"] is None
        assert data["group_name"] is None
        assert set(data["allowed_group_ids"]) == {str(g1.id), str(g2.id)}
        room = GameRoom.objects.get(pk=data["id"])
        assert set(room.allowed_groups.values_list("id", flat=True)) == {g1.id, g2.id}

    def test_create_group_whitelist_with_invalid_group_400(self, auth_client):
        """白名单含不存在/非群会话 → 400（set_allowed_groups 校验）。"""
        client, owner = auth_client(username="b_wl_bad")
        g1 = _make_group(owner)
        resp = client.post(
            "/api/v1/boardgame/rooms/",
            {
                "name": "x",
                "visibility": Visibility.GROUP,
                "allowed_group_ids": [str(g1.id), "999999"],
            },
            format="json",
        )
        assert resp.status_code == 400

    def test_create_group_must_be_group_conversation(self, auth_client, user_factory):
        client, user = auth_client(username="b_grp_conv")
        peer = user_factory(username="b_grp_peer")
        priv = Conversation.objects.create(type="private", owner=user)
        ConversationMember.objects.create(conversation=priv, user=user)
        ConversationMember.objects.create(conversation=priv, user=peer)
        resp = client.post(
            "/api/v1/boardgame/rooms/",
            {"name": "x", "group": str(priv.id)},
            format="json",
        )
        assert resp.status_code == 400
        assert "群" in resp.json()["detail"]


# ---------- 列表可见性 ----------

@pytest.mark.django_db
class TestRoomList:
    def test_list_filters_by_visibility(self, auth_client, user_factory):
        client, viewer = auth_client(username="l_viewer")
        owner = user_factory(username="l_owner")
        friend = user_factory(username="l_friend")
        member = user_factory(username="l_member")
        _make_friends(owner, friend)
        group = _make_group(owner, [member])

        _make_room(owner, "pub", visibility=Visibility.PUBLIC)
        _make_room(owner, "fri", visibility=Visibility.FRIENDS)
        _make_room(owner, "grp", visibility=Visibility.GROUP, group=group)

        resp = client.get("/api/v1/boardgame/rooms/")
        assert resp.status_code == 200
        names = {r["name"] for r in resp.json()}
        assert names == {"pub"}

        _make_friends(viewer, owner)
        resp = client.get("/api/v1/boardgame/rooms/")
        names = {r["name"] for r in resp.json()}
        assert names == {"pub", "fri"}

        ConversationMember.objects.create(conversation=group, user=viewer)
        resp = client.get("/api/v1/boardgame/rooms/")
        names = {r["name"] for r in resp.json()}
        assert names == {"pub", "fri", "grp"}

    def test_list_group_whitelist_visible_to_members_only(self, auth_client, user_factory):
        """Bug #10 契约：无归属群、仅白名单的 group 房，白名单群成员可见、非成员不可见。"""
        client, viewer = auth_client(username="lw_viewer")
        owner = user_factory(username="lw_owner")
        member = user_factory(username="lw_member")
        g1 = _make_group(owner, [member])
        g2 = _make_group(owner)
        room = _make_room(owner, "白名单房", visibility=Visibility.GROUP)
        room.allowed_groups.set([g1, g2])

        # 非成员：不可见
        resp = client.get("/api/v1/boardgame/rooms/")
        names = {r["name"] for r in resp.json()}
        assert "白名单房" not in names

        # viewer 加入 g1（g2 成员为空）后可见
        ConversationMember.objects.create(conversation=g1, user=viewer)
        resp = client.get("/api/v1/boardgame/rooms/")
        names = {r["name"] for r in resp.json()}
        assert "白名单房" in names

    def test_list_mine(self, auth_client, user_factory):
        client, me = auth_client(username="l_me")
        owner = user_factory(username="l_owner2")
        mine = _make_room(owner, "我加入的")
        GameRoomMember.objects.create(room=mine, user=me)
        _make_room(owner, "没加入的")
        resp = client.get("/api/v1/boardgame/rooms/?mine=1")
        names = {r["name"] for r in resp.json()}
        assert names == {"我加入的"}


# ---------- 详情 / 删除 ----------

@pytest.mark.django_db
class TestRoomDetail:
    def test_detail_forbidden_for_invisible(self, auth_client, user_factory):
        client, _ = auth_client(username="d_viewer")
        owner = user_factory(username="d_owner")
        room = _make_room(owner, "私密房", visibility=Visibility.FRIENDS)
        resp = client.get(f"/api/v1/boardgame/rooms/{room.id}/")
        assert resp.status_code == 403
        assert "无权" in resp.json()["detail"]

    def test_detail_author_visible(self, auth_client):
        client, user = auth_client(username="d_author")
        room = _make_room(user, "自己的房", visibility=Visibility.FRIENDS)
        resp = client.get(f"/api/v1/boardgame/rooms/{room.id}/")
        assert resp.status_code == 200
        assert resp.json()["name"] == "自己的房"

    def test_delete_only_owner(self, auth_client, user_factory):
        client, owner = auth_client(username="d_del_owner")
        room = _make_room(owner, "要删的房")
        stranger_client, _ = auth_client(username="d_del_stranger")
        assert (
            stranger_client.delete(f"/api/v1/boardgame/rooms/{room.id}/").status_code
            == 403
        )
        resp = client.delete(f"/api/v1/boardgame/rooms/{room.id}/")
        assert resp.status_code == 200
        assert not GameRoom.objects.filter(pk=room.id).exists()


# ---------- join / leave ----------

@pytest.mark.django_db
class TestRoomJoinLeave:
    def test_join_creates_member(self, auth_client, user_factory):
        client, joiner = auth_client(username="j_joiner")
        owner = user_factory(username="j_owner")
        room = _make_room(owner, "公开房")
        resp = client.post(f"/api/v1/boardgame/rooms/{room.id}:join/", format="json")
        assert resp.status_code == 201, resp.content
        data = resp.json()
        assert data["user_id"] == joiner.id
        assert data["seat"] == 0
        assert GameRoomMember.objects.filter(room=room, user=joiner).count() == 1

    def test_join_idempotent(self, auth_client, user_factory):
        client, joiner = auth_client(username="j_idem")
        owner = user_factory(username="j_idem_owner")
        room = _make_room(owner, "公开房")
        first = client.post(f"/api/v1/boardgame/rooms/{room.id}:join/", format="json")
        second = client.post(f"/api/v1/boardgame/rooms/{room.id}:join/", format="json")
        assert first.status_code == 201
        assert second.status_code == 200  # 幂等复用，不新建
        assert second.json()["id"] == first.json()["id"]
        assert GameRoomMember.objects.filter(room=room, user=joiner).count() == 1

    def test_join_invisible_403(self, auth_client, user_factory):
        client, _ = auth_client(username="j_out")
        owner = user_factory(username="j_f_owner")
        room = _make_room(owner, "好友房", visibility=Visibility.FRIENDS)
        resp = client.post(f"/api/v1/boardgame/rooms/{room.id}:join/", format="json")
        assert resp.status_code == 403

    def test_seat_assigned_in_order(self, auth_client, user_factory):
        owner = user_factory(username="s_owner")
        room = _make_room(owner, "座位房")
        for i in range(3):
            u = user_factory(username=f"s_u{i}")
            GameRoomMember.objects.create(room=room, user=u, seat=i)
        client, joiner = auth_client(username="s_joiner")
        resp = client.post(f"/api/v1/boardgame/rooms/{room.id}:join/", format="json")
        assert resp.status_code == 201
        assert resp.json()["seat"] == 3  # 已 3 人 → 下一个座位号 3

    def test_leave_member(self, auth_client, user_factory):
        client, joiner = auth_client(username="v_joiner")
        owner = user_factory(username="v_owner")
        room = _make_room(owner, "公开房")
        client.post(f"/api/v1/boardgame/rooms/{room.id}:join/", format="json")
        resp = client.post(f"/api/v1/boardgame/rooms/{room.id}:leave/", format="json")
        assert resp.status_code == 200
        assert not GameRoomMember.objects.filter(room=room, user=joiner).exists()

    def test_owner_leave_alone_400(self, auth_client):
        """房主作为唯一成员时离开 → 400（无人可转让）。"""
        client, owner = auth_client(username="g_leave_alone")
        room = _make_room(owner, "仅房主房")
        GameRoomMember.objects.create(room=room, user=owner)
        resp = client.post(f"/api/v1/boardgame/rooms/{room.id}:leave/", format="json")
        assert resp.status_code == 400
        assert "先转让" in resp.json()["detail"]

    def test_leave_non_member_400(self, auth_client, user_factory):
        client, outsider = auth_client(username="v_out")
        owner = user_factory(username="v_owner2")
        room = _make_room(owner, "公开房")
        resp = client.post(f"/api/v1/boardgame/rooms/{room.id}:leave/", format="json")
        assert resp.status_code == 400

    def test_members_and_count_in_serializer(self, auth_client, user_factory):
        client, joiner = auth_client(username="m_joiner")
        owner = user_factory(username="m_owner")
        room = _make_room(owner, "成员房")
        client.post(f"/api/v1/boardgame/rooms/{room.id}:join/", format="json")
        resp = client.get(f"/api/v1/boardgame/rooms/{room.id}/")
        data = resp.json()
        assert data["member_count"] == 1
        assert data["is_member"] is True
        assert len(data["members"]) == 1
        assert data["members"][0]["user_id"] == joiner.id

    def test_owner_member_actions_and_leave_contract(self, auth_client, user_factory):
        owner_client, owner = auth_client(username="g_owner_actions")
        member = user_factory(username="g_member_actions")
        room = _make_room(owner, "管理桌游房")
        GameRoomMember.objects.create(room=room, user=owner)
        GameRoomMember.objects.create(room=room, user=member, seat=1)

        kicked = owner_client.post(
            f"/api/v1/boardgame/rooms/{room.id}/members/{member.id}/action/",
            {"action": "kick"}, format="json",
        )
        assert kicked.status_code == 200, kicked.content
        assert not GameRoomMember.objects.filter(room=room, user=member).exists()

        GameRoomMember.objects.create(room=room, user=member, seat=1)
        transferred = owner_client.post(
            f"/api/v1/boardgame/rooms/{room.id}/members/{member.id}/action/",
            {"action": "transfer"}, format="json",
        )
        assert transferred.status_code == 200, transferred.content
        room.refresh_from_db()
        assert room.owner_id == member.id
        # 转让后响应必须反映新房主（不因序列化复用 select_related "owner" 缓存返回旧房主）
        tdata = transferred.json()
        assert tdata["owner_id"] == member.id
        assert tdata["is_owner"] is False  # 发起人不再是房主
        # members 按 seat 排序（owner=0 / member=1），用集合断言不依赖顺序
        member_ids = {m["user_id"] for m in tdata["members"]}
        assert member_ids == {owner.id, member.id}
        resp = owner_client.post(f"/api/v1/boardgame/rooms/{room.id}:leave/")
        assert resp.status_code == 200, resp.content

    def test_kick_response_reflects_removed_member(self, auth_client, user_factory):
        """踢人后响应 members/成员数反映移除（不因 prefetch 缓存返回已被踢成员）。"""
        owner_client, owner = auth_client(username="g_kick_owner")
        member = user_factory(username="g_kick_member")
        room = _make_room(owner, "踢人响应桌游房")
        GameRoomMember.objects.create(room=room, user=owner)
        GameRoomMember.objects.create(room=room, user=member, seat=1)

        resp = owner_client.post(
            f"/api/v1/boardgame/rooms/{room.id}/members/{member.id}/action/",
            {"action": "kick"}, format="json",
        )
        assert resp.status_code == 200, resp.content
        data = resp.json()
        assert data["member_count"] == 1
        member_ids = {m["user_id"] for m in data["members"]}
        assert member_ids == {owner.id}
        assert member.id not in member_ids
