"""群聊子群 REST 契约测试：默认组、CRUD 权限、删除归并、消息归属、独立未读。"""
import pytest

from apps.chat.models import ConversationMember, GroupSubGroup, Message
from apps.chat.tests.helpers import auth_as, make_group


def _subgroups(client, conv_id):
    resp = client.get(f"/api/v1/chat/conversations/{conv_id}/subgroups/")
    assert resp.status_code == 200, resp.content
    return resp.json()


def _default_subgroup(client, conv_id):
    items = _subgroups(client, conv_id)
    return next(item for item in items if item["is_default"])


def _send(client, conv_id, content="hi", **extra):
    resp = client.post(
        f"/api/v1/chat/conversations/{conv_id}/messages/",
        {"type": "text", "content": content, **extra},
        format="json",
    )
    assert resp.status_code == 201, resp.content
    return resp.json()


@pytest.mark.django_db
class TestSubGroupBasics:
    def test_new_group_has_default_subgroup(self, auth_client, user_factory):
        b = user_factory(username="sg_b")
        ca, _ = auth_client(username="sg_a")
        conv = make_group(ca, [b])
        items = _subgroups(ca, conv["id"])
        assert len(items) == 1
        assert items[0]["name"] == "默认组"
        assert items[0]["is_default"] is True
        assert items[0]["unread_count"] == 0

    def test_member_can_list_outsider_forbidden(self, auth_client, user_factory):
        b = user_factory(username="sg2_b")
        outsider = user_factory(username="sg2_out")
        ca, _ = auth_client(username="sg2_a")
        conv = make_group(ca, [b])
        cb = auth_as(b)
        assert _subgroups(cb, conv["id"])  # 成员可看
        cout = auth_as(outsider)
        assert (
            cout.get(f"/api/v1/chat/conversations/{conv['id']}/subgroups/").status_code
            == 403
        )

    def test_private_conversation_has_no_subgroups(self, auth_client, user_factory):
        b = user_factory(username="sg3_b")
        ca, _ = auth_client(username="sg3_a")
        from apps.chat.tests.helpers import make_private

        conv = make_private(ca, auth_as(b))
        resp = ca.get(f"/api/v1/chat/conversations/{conv['id']}/subgroups/")
        assert resp.status_code == 400


@pytest.mark.django_db
class TestSubGroupCrud:
    def test_owner_create_rename_delete(self, auth_client, user_factory):
        b = user_factory(username="sgc_b")
        ca, _ = auth_client(username="sgc_a")
        conv = make_group(ca, [b])
        # 创建
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/",
            {"name": "闲聊"},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        sg = resp.json()
        assert sg["name"] == "闲聊"
        assert sg["is_default"] is False
        # 改名
        resp = ca.patch(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/{sg['id']}/",
            {"name": "水群"},
            format="json",
        )
        assert resp.status_code == 200, resp.content
        assert resp.json()["name"] == "水群"
        # 删除
        assert (
            ca.delete(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/{sg['id']}/"
            ).status_code
            == 200
        )
        assert not GroupSubGroup.objects.filter(pk=sg["id"]).exists()

    def test_admin_can_manage_member_forbidden(self, auth_client, user_factory):
        b = user_factory(username="sgc2_admin")
        c = user_factory(username="sgc2_member")
        ca, _ = auth_client(username="sgc2_owner")
        conv = make_group(ca, [b, c])
        ConversationMember.objects.filter(
            conversation_id=conv["id"], user=b
        ).update(role="admin")
        cadmin = auth_as(b)
        resp = cadmin.post(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/",
            {"name": "管理员建的"},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        cmember = auth_as(c)
        assert (
            cmember.post(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/",
                {"name": "成员建的"},
                format="json",
            ).status_code
            == 403
        )
        sg = resp.json()
        assert (
            cmember.patch(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/{sg['id']}/",
                {"name": "改名"},
                format="json",
            ).status_code
            == 403
        )
        assert (
            cmember.delete(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/{sg['id']}/"
            ).status_code
            == 403
        )

    def test_validation(self, auth_client, user_factory):
        b = user_factory(username="sgc3_b")
        ca, _ = auth_client(username="sgc3_a")
        conv = make_group(ca, [b])
        assert (
            ca.post(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/",
                {"name": "  "},
                format="json",
            ).status_code
            == 400
        )
        assert (
            ca.post(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/",
                {"name": "x" * 65},
                format="json",
            ).status_code
            == 400
        )
        assert (
            ca.post(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/",
                {"name": "重名"},
                format="json",
            ).status_code
            == 201
        )
        assert (
            ca.post(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/",
                {"name": "重名"},
                format="json",
            ).status_code
            == 400
        )

    def test_default_subgroup_cannot_delete_but_can_rename(self, auth_client, user_factory):
        b = user_factory(username="sgc4_b")
        ca, _ = auth_client(username="sgc4_a")
        conv = make_group(ca, [b])
        default = _default_subgroup(ca, conv["id"])
        assert (
            ca.delete(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/{default['id']}/"
            ).status_code
            == 400
        )
        resp = ca.patch(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/{default['id']}/",
            {"name": "主群"},
            format="json",
        )
        assert resp.status_code == 200, resp.content
        assert resp.json()["name"] == "主群"


@pytest.mark.django_db
class TestSubGroupMessageOwnership:
    def test_message_goes_to_subgroup_and_history_filters(self, auth_client, user_factory):
        b = user_factory(username="sgm_b")
        ca, _ = auth_client(username="sgm_a")
        conv = make_group(ca, [b])
        default = _default_subgroup(ca, conv["id"])
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/",
            {"name": "闲聊"},
            format="json",
        )
        sg = resp.json()

        # 不带 subgroup_id → subgroup 为 null（默认组视图语义：null 归默认组）
        m1 = _send(ca, conv["id"], "默认组消息")
        assert m1["subgroup_id"] is None
        # 带 subgroup_id → 该子群
        m2 = _send(ca, conv["id"], "闲聊消息", subgroup_id=int(sg["id"]))
        assert m2["subgroup_id"] == sg["id"]

        # 历史按子群过滤
        resp = ca.get(
            f"/api/v1/chat/conversations/{conv['id']}/messages/?subgroup_id={sg['id']}"
        )
        assert resp.status_code == 200
        assert [m["id"] for m in resp.json()] == [m2["id"]]
        resp = ca.get(
            f"/api/v1/chat/conversations/{conv['id']}/messages/?subgroup_id={default['id']}"
        )
        # 默认组视图包含 subgroup 为 null 的旧消息
        assert [m["id"] for m in resp.json()] == [m1["id"]]
        # 不传 subgroup_id → 全部
        resp = ca.get(f"/api/v1/chat/conversations/{conv['id']}/messages/")
        assert len(resp.json()) == 2

    def test_invalid_subgroup_rejected(self, auth_client, user_factory):
        b = user_factory(username="sgm2_b")
        ca, _ = auth_client(username="sgm2_a")
        conv = make_group(ca, [b])
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"type": "text", "content": "x", "subgroup_id": 999999},
            format="json",
        )
        assert resp.status_code == 400
        # 私聊不能指定子群
        from apps.chat.tests.helpers import make_private

        pconv = make_private(ca, auth_as(b))
        resp = ca.post(
            f"/api/v1/chat/conversations/{pconv['id']}/messages/",
            {"type": "text", "content": "x", "subgroup_id": 1},
            format="json",
        )
        assert resp.status_code == 400

    def test_delete_subgroup_removes_messages(self, auth_client, user_factory):
        b = user_factory(username="sgm3_b")
        ca, _ = auth_client(username="sgm3_a")
        conv = make_group(ca, [b])
        default = _default_subgroup(ca, conv["id"])
        sg = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/",
            {"name": "临时"},
            format="json",
        ).json()
        _send(ca, conv["id"], "临时消息", subgroup_id=int(sg["id"]))
        assert (
            ca.delete(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/{sg['id']}/"
            ).status_code
            == 200
        )
        # 子群删除后其聊天记录一并永久删除
        assert not Message.objects.filter(content="临时消息").exists()
        # 默认组历史不含被删子群的消息
        resp = ca.get(
            f"/api/v1/chat/conversations/{conv['id']}/messages/?subgroup_id={default['id']}"
        )
        assert resp.json() == []


@pytest.mark.django_db
class TestSubGroupUnread:
    def test_unread_per_subgroup_and_mark_read(self, auth_client, user_factory):
        b = user_factory(username="sgu_b")
        ca, _ = auth_client(username="sgu_a")
        conv = make_group(ca, [b])
        default = _default_subgroup(ca, conv["id"])
        sg = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/",
            {"name": "闲聊"},
            format="json",
        ).json()
        cb = auth_as(b)
        # b 在默认组发 1 条、闲聊发 2 条 → a 的未读按子群独立
        _send(cb, conv["id"], "默认1")
        _send(cb, conv["id"], "闲聊1", subgroup_id=int(sg["id"]))
        _send(cb, conv["id"], "闲聊2", subgroup_id=int(sg["id"]))

        items = _subgroups(ca, conv["id"])
        by_id = {item["id"]: item for item in items}
        assert by_id[default["id"]]["unread_count"] == 1
        assert by_id[sg["id"]]["unread_count"] == 2
        assert len(by_id[sg["id"]]["unread_seqs"]) == 2

        # 标闲聊已读 → 只清闲聊，默认组不受影响
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/{sg['id']}/read/"
        )
        assert resp.status_code == 200
        assert resp.json()["marked"] == 2
        items = _subgroups(ca, conv["id"])
        by_id = {item["id"]: item for item in items}
        assert by_id[sg["id"]]["unread_count"] == 0
        assert by_id[default["id"]]["unread_count"] == 1
        # 幂等：再标一次 marked=0
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/{sg['id']}/read/"
        )
        assert resp.json()["marked"] == 0

    def test_own_messages_not_unread(self, auth_client, user_factory):
        b = user_factory(username="sgu2_b")
        ca, _ = auth_client(username="sgu2_a")
        conv = make_group(ca, [b])
        _send(ca, conv["id"], "自己发的")
        items = _subgroups(ca, conv["id"])
        assert all(item["unread_count"] == 0 for item in items)


@pytest.mark.django_db
class TestSubGroupMute:
    def test_owner_toggles_mute_and_member_blocked(self, auth_client, user_factory):
        b = user_factory(username="sgmute_b")
        ca, _ = auth_client(username="sgmute_a")
        conv = make_group(ca, [b])
        sg = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/",
            {"name": "公告"},
            format="json",
        ).json()
        cb = auth_as(b)
        # 普通成员不能改开关
        assert (
            cb.patch(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/{sg['id']}/",
                {"muted": True},
                format="json",
            ).status_code
            == 403
        )
        # 群主开启禁言
        resp = ca.patch(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/{sg['id']}/",
            {"muted": True},
            format="json",
        )
        assert resp.status_code == 200, resp.content
        assert resp.json()["muted"] is True
        # 普通成员发消息 403
        resp = cb.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"type": "text", "content": "被禁言", "subgroup_id": int(sg["id"])},
            format="json",
        )
        assert resp.status_code == 403
        # 群主可发
        assert (
            ca.post(
                f"/api/v1/chat/conversations/{conv['id']}/messages/",
                {"type": "text", "content": "群主发言", "subgroup_id": int(sg["id"])},
                format="json",
            ).status_code
            == 201
        )
        # 管理员可发
        ConversationMember.objects.filter(
            conversation_id=conv["id"], user=b
        ).update(role="admin")
        cadmin = auth_as(b)
        assert (
            cadmin.post(
                f"/api/v1/chat/conversations/{conv['id']}/messages/",
                {"type": "text", "content": "管理员发言", "subgroup_id": int(sg["id"])},
                format="json",
            ).status_code
            == 201
        )
        # 关闭禁言后普通成员可发
        assert (
            ca.patch(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/{sg['id']}/",
                {"muted": False},
                format="json",
            ).status_code
            == 200
        )
        cmember = auth_as(b)
        ConversationMember.objects.filter(
            conversation_id=conv["id"], user=b
        ).update(role="member")
        assert (
            cmember.post(
                f"/api/v1/chat/conversations/{conv['id']}/messages/",
                {"type": "text", "content": "解禁后", "subgroup_id": int(sg["id"])},
                format="json",
            ).status_code
            == 201
        )

    def test_default_subgroup_mute_blocks_no_subgroup_send(self, auth_client, user_factory):
        b = user_factory(username="sgmute2_b")
        ca, _ = auth_client(username="sgmute2_a")
        conv = make_group(ca, [b])
        default = _default_subgroup(ca, conv["id"])
        assert (
            ca.patch(
                f"/api/v1/chat/conversations/{conv['id']}/subgroups/{default['id']}/",
                {"muted": True},
                format="json",
            ).status_code
            == 200
        )
        cb = auth_as(b)
        # 不传 subgroup_id（归默认组）同样被禁言拦截
        resp = cb.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"type": "text", "content": "默认组被禁"},
            format="json",
        )
        assert resp.status_code == 403

    def test_mute_validation(self, auth_client, user_factory):
        b = user_factory(username="sgmute3_b")
        ca, _ = auth_client(username="sgmute3_a")
        conv = make_group(ca, [b])
        sg = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/",
            {"name": "测试"},
            format="json",
        ).json()
        resp = ca.patch(
            f"/api/v1/chat/conversations/{conv['id']}/subgroups/{sg['id']}/",
            {"muted": "yes"},
            format="json",
        )
        assert resp.status_code == 400
