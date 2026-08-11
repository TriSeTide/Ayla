"""emoji REST 契约测试（8.1 清单：系统包、收藏/取消、发 emoji 消息引用校验）。"""
import pytest

from apps.media.models import MediaObject

from .conftest import upload_emoji  # 转发 media conftest


@pytest.mark.django_db
class TestEmojiAPI:
    def test_list_system_and_personal_packs(self, auth_client):
        client, user = auth_client(username="ej_a")
        from apps.emoji.models import EmojiPack
        EmojiPack.objects.create(owner=user, name="我的包", is_system=False)
        EmojiPack.objects.create(owner=None, name="系统包", is_system=True)
        resp = client.get("/api/v1/emoji/packs/")
        assert resp.status_code == 200
        names = {p["name"] for p in resp.json()}
        assert "我的包" in names
        assert "系统包" in names

    def test_create_personal_pack_and_collect_emoji(self, auth_client):
        client, user = auth_client(username="ej_b")
        # 建个人包
        resp = client.post("/api/v1/emoji/packs/", {"name": "收藏"}, format="json")
        assert resp.status_code == 201
        pack_id = resp.json()["id"]
        # 上传 emoji 媒体（kind=emoji）
        media_id, _ = upload_emoji(client)
        # 收藏
        resp = client.post(
            f"/api/v1/emoji/packs/{pack_id}/items/add/",
            {"media_id": media_id, "tag": "哈哈"},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        item_id = resp.json()["id"]
        # 包内列表
        resp = client.get(f"/api/v1/emoji/packs/{pack_id}/items/")
        assert resp.status_code == 200
        assert len(resp.json()) == 1
        # 重复收藏幂等 → 200（不重复建）
        resp2 = client.post(
            f"/api/v1/emoji/packs/{pack_id}/items/add/",
            {"media_id": media_id},
            format="json",
        )
        assert resp2.status_code == 200
        # 取消收藏
        resp = client.delete(f"/api/v1/emoji/packs/{pack_id}/items/{item_id}/")
        assert resp.status_code == 204

    def test_collect_non_emoji_kind_rejected(self, auth_client):
        client, user = auth_client(username="ej_c")
        resp = client.post("/api/v1/emoji/packs/", {"name": "p"}, format="json")
        pack_id = resp.json()["id"]
        # 上传 image（非 emoji）媒体
        from apps.media.tests.conftest import upload_image
        media_id, _ = upload_image(client, kind="image", mime_type="image/png")
        resp = client.post(
            f"/api/v1/emoji/packs/{pack_id}/items/add/",
            {"media_id": media_id},
            format="json",
        )
        assert resp.status_code == 400

    def test_cannot_collect_into_others_pack(self, auth_client, user_factory):
        owner_client, owner = auth_client(username="ej_d")
        resp = owner_client.post("/api/v1/emoji/packs/", {"name": "p"}, format="json")
        pack_id = resp.json()["id"]
        media_id, _ = upload_emoji(owner_client)
        stranger = user_factory(username="ej_d2")
        from apps.media.tests.helpers import auth_as
        sc = auth_as(stranger)
        resp = sc.post(
            f"/api/v1/emoji/packs/{pack_id}/items/add/",
            {"media_id": media_id},
            format="json",
        )
        assert resp.status_code == 403

    def test_system_pack_visible_and_send_emoji_message(self, auth_client, user_factory):
        client, user = auth_client(username="ej_e")
        # 建系统包 + 系统媒体
        from apps.emoji.models import EmojiPack, EmojiItem
        from apps.emoji.services import get_or_create_system_pack
        pack = get_or_create_system_pack("默认表情")
        media_id, _ = upload_emoji(client)
        media = MediaObject.objects.get(media_id=media_id)
        EmojiItem.objects.create(pack=pack, media=media, tag="默认")
        # 另一用户也应可见系统包并可发 emoji 消息
        other = user_factory(username="ej_e2")
        from apps.media.tests.helpers import auth_as
        oc = auth_as(other)
        resp = oc.get("/api/v1/emoji/packs/")
        assert any(p["is_system"] for p in resp.json())
        # 其它用户发 emoji 消息（须有访问权：系统包媒体全员可见）
        from apps.chat.services import get_or_create_conversation
        conv = get_or_create_conversation(other, user)
        resp = oc.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"type": "emoji", "media_id": media_id, "idempotency_key": "ej-emoji-1"},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        assert resp.json()["type"] == "emoji"
