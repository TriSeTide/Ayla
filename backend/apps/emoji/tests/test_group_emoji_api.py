"""任务 03：群内表情包 REST 契约测试。

覆盖：群包可见性（群成员）、上传权限（默认群主/管理员、开关开启后普通成员）、
删除权限（群主/管理员）、开关仅群主可改、非成员 403。
"""
import pytest

from apps.chat.models import Conversation, ConversationMember
from apps.chat.tests.helpers import auth_as

from .conftest import upload_emoji


def _group_pack_url(conv_id):
    return f"/api/v1/emoji/groups/{conv_id}/pack/"


@pytest.mark.django_db
class TestGroupEmojiAPI:
    def _setup_group(self, auth_client, user_factory):
        """ORM 直建群：owner + admin + member 三人。

        不走 API 建群（make_group 会序列化会话，触发 M8 segments__contains，
        SQLite 测试环境必然 NotSupportedError——已知基线，见 test_poke.py 注释）。
        返回 (owner_client, admin_client, member_client, conv_id)。
        """
        owner_client, owner = auth_client(username="ge_owner")
        admin = user_factory(username="ge_admin")
        member = user_factory(username="ge_member")
        conv = Conversation.objects.create(
            type=Conversation.TYPE_GROUP, title="表情包测试群", owner=owner
        )
        ConversationMember.objects.create(
            conversation=conv, user=owner, role=ConversationMember.ROLE_OWNER
        )
        ConversationMember.objects.create(
            conversation=conv, user=admin, role=ConversationMember.ROLE_ADMIN
        )
        ConversationMember.objects.create(
            conversation=conv, user=member, role=ConversationMember.ROLE_MEMBER
        )
        return owner_client, auth_as(admin), auth_as(member), conv.id

    def test_group_pack_visible_to_members_and_owner_can_add(self, auth_client, user_factory):
        owner_client, admin_client, member_client, conv_id = self._setup_group(
            auth_client, user_factory
        )
        # 未创建时 GET → 404
        resp = member_client.get(_group_pack_url(conv_id))
        assert resp.status_code == 404
        # 群主上传 emoji 并加入群包
        media_id, _ = upload_emoji(owner_client, data=b"\x89PNG\r\n\x1a\nowner-del")
        resp = owner_client.post(
            f"/api/v1/emoji/groups/{conv_id}/pack/items/",
            {"media_id": media_id},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        # 群成员 GET 可见，can_upload 按角色
        resp = member_client.get(_group_pack_url(conv_id))
        assert resp.status_code == 200
        data = resp.json()
        assert data["pack"]["item_count"] == 1
        assert data["allow_member_upload"] is False
        assert data["can_upload"] is False  # 普通成员默认不可上传
        assert data["can_delete"] is False
        # 群主 can_upload/can_delete 为 true
        resp = owner_client.get(_group_pack_url(conv_id))
        data = resp.json()
        assert data["can_upload"] is True
        assert data["can_delete"] is True

    def test_member_upload_rejected_by_default_admin_allowed(self, auth_client, user_factory):
        owner_client, admin_client, member_client, conv_id = self._setup_group(
            auth_client, user_factory
        )
        media_id, _ = upload_emoji(member_client, data=b"\x89PNG\r\n\x1a\nmember-unique")
        # 普通成员默认 403
        resp = member_client.post(
            f"/api/v1/emoji/groups/{conv_id}/pack/items/",
            {"media_id": media_id},
            format="json",
        )
        assert resp.status_code == 403
        # 管理员可上传（不同内容避免 content_hash 去重复用 member 的 media）
        media_id2, _ = upload_emoji(admin_client, data=b"\x89PNG\r\n\x1a\nadmin-unique")
        resp = admin_client.post(
            f"/api/v1/emoji/groups/{conv_id}/pack/items/",
            {"media_id": media_id2},
            format="json",
        )
        assert resp.status_code == 201, resp.content

    def test_owner_toggle_member_upload(self, auth_client, user_factory):
        owner_client, admin_client, member_client, conv_id = self._setup_group(
            auth_client, user_factory
        )
        # 非群主（管理员）PATCH → 403
        resp = admin_client.patch(
            _group_pack_url(conv_id),
            {"allow_member_upload": True},
            format="json",
        )
        assert resp.status_code == 403
        # 群主开启
        resp = owner_client.patch(
            _group_pack_url(conv_id),
            {"allow_member_upload": True},
            format="json",
        )
        assert resp.status_code == 200, resp.content
        assert resp.json()["allow_member_upload"] is True
        # 普通成员现在可上传
        media_id, _ = upload_emoji(member_client, data=b"\x89PNG\r\n\x1a\nmember-open")
        resp = member_client.post(
            f"/api/v1/emoji/groups/{conv_id}/pack/items/",
            {"media_id": media_id},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        # 群主关闭 → 普通成员恢复禁止
        resp = owner_client.patch(
            _group_pack_url(conv_id),
            {"allow_member_upload": False},
            format="json",
        )
        assert resp.status_code == 200
        media_id2, _ = upload_emoji(member_client, data=b"\x89PNG\r\n\x1a\nmember-closed")
        resp = member_client.post(
            f"/api/v1/emoji/groups/{conv_id}/pack/items/",
            {"media_id": media_id2},
            format="json",
        )
        assert resp.status_code == 403

    def test_delete_only_owner_or_admin(self, auth_client, user_factory):
        owner_client, admin_client, member_client, conv_id = self._setup_group(
            auth_client, user_factory
        )
        media_id, _ = upload_emoji(owner_client, data=b"\x89PNG\r\n\x1a\nowner-del")
        resp = owner_client.post(
            f"/api/v1/emoji/groups/{conv_id}/pack/items/",
            {"media_id": media_id},
            format="json",
        )
        item_id = resp.json()["id"]
        # 普通成员不可删（即使开关开启）
        owner_client.patch(
            _group_pack_url(conv_id),
            {"allow_member_upload": True},
            format="json",
        )
        resp = member_client.delete(
            f"/api/v1/emoji/groups/{conv_id}/pack/items/{item_id}/"
        )
        assert resp.status_code == 403
        # 管理员可删
        resp = admin_client.delete(
            f"/api/v1/emoji/groups/{conv_id}/pack/items/{item_id}/"
        )
        assert resp.status_code == 204
        resp = member_client.get(_group_pack_url(conv_id))
        assert resp.json()["pack"]["item_count"] == 0

    def test_non_member_forbidden(self, auth_client, user_factory):
        owner_client, admin_client, member_client, conv_id = self._setup_group(
            auth_client, user_factory
        )
        outsider = user_factory(username="ge_outsider")
        outsider_client = auth_as(outsider)
        resp = outsider_client.get(_group_pack_url(conv_id))
        assert resp.status_code == 403
        media_id, _ = upload_emoji(outsider_client)
        resp = outsider_client.post(
            f"/api/v1/emoji/groups/{conv_id}/pack/items/",
            {"media_id": media_id},
            format="json",
        )
        assert resp.status_code == 403

    def test_same_content_image_then_emoji_kind(self, auth_client, user_factory):
        """同内容先以 image 上传、再以 emoji 上传 → 群包添加成功。

        回归：content_hash 去重曾不区分 kind，先发过同图（kind=image）再传群表情包
        （kind=emoji）会复用到 image media，add_item 报 media_type_mismatch。
        """
        from apps.media.tests.conftest import upload_image

        owner_client, admin_client, member_client, conv_id = self._setup_group(
            auth_client, user_factory
        )
        data = b"\x89PNG\r\n\x1a\nsame-content-both-kinds"
        media_id_img, _ = upload_image(
            owner_client, data=data, kind="image", mime_type="image/png"
        )
        media_id_emoji, _ = upload_emoji(owner_client, data=data)
        # 不同 kind 不复用：各自独立 media
        assert media_id_img != media_id_emoji
        resp = owner_client.post(
            f"/api/v1/emoji/groups/{conv_id}/pack/items/",
            {"media_id": media_id_emoji},
            format="json",
        )
        assert resp.status_code == 201, resp.content

    def test_heic_emoji_upload_allowed(self, auth_client, user_factory):
        """HEIC/AVIF 等现代图片格式可作群表情（emoji 白名单对齐 image，回归）。"""
        owner_client, admin_client, member_client, conv_id = self._setup_group(
            auth_client, user_factory
        )
        from apps.media.tests.conftest import upload_image

        # HEIC 魔数（ISOBMFF ftyp 分支）——用合法头部字节
        data = b"\x00\x00\x00\x18ftypheic" + b"\x00" * 40
        media_id, _ = upload_image(
            owner_client, data=data, kind="emoji", mime_type="image/heic"
        )
        resp = owner_client.post(
            f"/api/v1/emoji/groups/{conv_id}/pack/items/",
            {"media_id": media_id},
            format="json",
        )
        assert resp.status_code == 201, resp.content

    def test_send_group_emoji_as_message(self, auth_client, user_factory):
        """群表情加入后，成员可发 type=emoji 消息（复用现有消息链路）。"""
        owner_client, admin_client, member_client, conv_id = self._setup_group(
            auth_client, user_factory
        )
        media_id, _ = upload_emoji(owner_client, data=b"\x89PNG\r\n\x1a\nowner-send")
        owner_client.post(
            f"/api/v1/emoji/groups/{conv_id}/pack/items/",
            {"media_id": media_id},
            format="json",
        )
        resp = member_client.post(
            f"/api/v1/chat/conversations/{conv_id}/messages/",
            {
                "type": "emoji",
                "content": "",
                "media_id": media_id,
                "idempotency_key": "ge-msg-1",
            },
            format="json",
        )
        assert resp.status_code == 201, resp.content
        assert resp.json()["type"] == "emoji"
