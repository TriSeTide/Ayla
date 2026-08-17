"""chat 消息 REST 契约测试：发消息/幂等/seq/历史/已读/撤回/禁言/越权。

全部不依赖 Redis/MySQL。
"""
from datetime import timedelta

import pytest
from django.utils import timezone

from apps.chat.models import ConversationMember, Message, MessageRead
from apps.chat.tests.helpers import auth_as, make_group, make_private, new_key


@pytest.mark.django_db
class TestMessageCreate:
    def test_send_text_message(self, auth_client, user_factory):
        b = user_factory(username="ms_b")
        ca, a = auth_client(username="ms_a")
        conv = make_private(ca, auth_as(b))
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"type": "text", "content": "你好", "idempotency_key": new_key()},
            format="json",
        )
        assert resp.status_code == 201
        body = resp.json()
        assert body["content"] == "你好"
        assert body["sender_id"] == str(a.id)
        assert body["conversation_id"] == conv["id"]
        assert body["seq"] == 1
        assert body["status"] == "sent"

    def test_message_serialization_shape(self, auth_client, user_factory):
        b = user_factory(username="ms2_b")
        ca, _ = auth_client(username="ms2_a")
        conv = make_private(ca, auth_as(b))
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "形状", "idempotency_key": new_key()},
            format="json",
        )
        body = resp.json()
        for field in [
            "id", "conversation_id", "sender_id", "type", "content",
            "media_id", "media", "reply_to", "status", "seq", "created_at",
        ]:
            assert field in body
        assert isinstance(body["id"], str)
        assert isinstance(body["seq"], int)
        assert body["media"] is None  # 文本消息无媒体引用

    def test_idempotent_resend_returns_original(self, auth_client, user_factory):
        b = user_factory(username="ms3_b")
        ca, _ = auth_client(username="ms3_a")
        conv = make_private(ca, auth_as(b))
        key = new_key()
        r1 = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "幂等", "idempotency_key": key},
            format="json",
        )
        assert r1.status_code == 201
        r2 = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "幂等", "idempotency_key": key},
            format="json",
        )
        assert r2.status_code == 200
        assert r2.json()["id"] == r1.json()["id"]
        assert Message.objects.filter(conversation_id=conv["id"]).count() == 1

    def test_same_key_different_content_409(self, auth_client, user_factory):
        b = user_factory(username="ms4_b")
        ca, _ = auth_client(username="ms4_a")
        conv = make_private(ca, auth_as(b))
        key = new_key()
        ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "原内容", "idempotency_key": key},
            format="json",
        )
        r2 = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "不同内容", "idempotency_key": key},
            format="json",
        )
        assert r2.status_code == 409

    def test_same_key_different_conv_409(self, auth_client, user_factory):
        """idempotency_key 全局唯一：不同会话复用同 key 报冲突。"""
        b = user_factory(username="ms5_b")
        c = user_factory(username="ms5_c")
        ca, _ = auth_client(username="ms5_a")
        conv1 = make_private(ca, auth_as(b))
        conv2 = make_private(ca, auth_as(c))
        key = new_key()
        r1 = ca.post(
            f"/api/v1/chat/conversations/{conv1['id']}/messages/",
            {"content": "x", "idempotency_key": key},
            format="json",
        )
        assert r1.status_code == 201
        r2 = ca.post(
            f"/api/v1/chat/conversations/{conv2['id']}/messages/",
            {"content": "x", "idempotency_key": key},
            format="json",
        )
        assert r2.status_code == 409

    def test_seq_monotonic_across_requests(self, auth_client, user_factory):
        b = user_factory(username="ms6_b")
        ca, _ = auth_client(username="ms6_a")
        conv = make_private(ca, auth_as(b))
        seqs = []
        for i in range(5):
            resp = ca.post(
                f"/api/v1/chat/conversations/{conv['id']}/messages/",
                {"content": f"m{i}", "idempotency_key": new_key()},
                format="json",
            )
            seqs.append(resp.json()["seq"])
        assert seqs == [1, 2, 3, 4, 5]

    def test_send_to_unknown_reply_404(self, auth_client, user_factory):
        b = user_factory(username="ms7_b")
        ca, _ = auth_client(username="ms7_a")
        conv = make_private(ca, auth_as(b))
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "x", "reply_to": 99999, "idempotency_key": new_key()},
            format="json",
        )
        assert resp.status_code == 404

    def test_muted_member_cannot_send(self, auth_client, user_factory):
        owner = auth_client(username="ms8_owner")
        member = user_factory(username="ms8_member")
        ca, _ = owner
        conv = make_group(ca, [member])
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/members/{member.id}/mute/",
            {"muted": True},
            format="json",
        )
        assert resp.status_code == 200
        cm = auth_as(member)
        resp = cm.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "禁言测试", "idempotency_key": new_key()},
            format="json",
        )
        assert resp.status_code == 403

    def test_send_image_message_with_real_media(self, auth_client, user_factory):
        """M4-3：发图片消息必须带存在且 ready 的真实媒体（三步上传后引用）。"""
        b = user_factory(username="ms9_b")
        ca, _ = auth_client(username="ms9_a")
        conv = make_private(ca, auth_as(b))
        # 上传真实图片媒体
        from apps.media.tests.conftest import upload_image

        media_id, _ = upload_image(ca)
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "type": "image",
                "content": "图片引用",
                "media_id": media_id,
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 201
        body = resp.json()
        assert body["type"] == "image"
        assert body["media_id"] == media_id
        # M4-3：media 升级为 descriptor 对象
        assert body["media"]["media_id"] == media_id
        assert body["media"]["kind"] == "image"
        assert body["media"]["status"] == "ready"

    def test_send_image_with_invalid_media_400(self, auth_client, user_factory):
        """M4-3：假/不存在 media_id → 400 media_not_found（原 M4-2 占位行为的契约变更）。"""
        b = user_factory(username="ms9b_b")
        ca, _ = auth_client(username="ms9b_a")
        conv = make_private(ca, auth_as(b))
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "type": "image",
                "content": "图片引用",
                "media_id": "media-placeholder-1",
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 400
        assert "media_not_found" in str(resp.json())

    def test_send_media_message_without_access_403(self, auth_client, user_factory):
        """M4-3：用别人 media_id 发消息 → 403 media_access_denied。"""
        owner_client, owner = auth_client(username="ms9c_o")
        from apps.media.tests.conftest import upload_image

        media_id, _ = upload_image(owner_client)
        # 另两人建立会话，但媒体属于 owner，发送者无访问权
        b = user_factory(username="ms9c_b")
        a = user_factory(username="ms9c_a")
        ca = auth_as(a)
        cb = auth_as(b)
        conv_a = make_private(ca, cb)
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv_a['id']}/messages/",
            {
                "type": "image",
                "content": "盗用",
                "media_id": media_id,
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 403

    def test_send_media_message_type_mismatch_400(self, auth_client, user_factory):
        """M4-3：media kind 与消息 type 不匹配 → 400 media_type_mismatch。"""
        b = user_factory(username="ms9d_b")
        ca, _ = auth_client(username="ms9d_a")
        conv = make_private(ca, auth_as(b))
        from apps.media.tests.conftest import upload_image

        # 上传 image 媒体，但发 voice 消息
        media_id, _ = upload_image(ca, kind="image", mime_type="image/png")
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "type": "voice",
                "content": "",
                "media_id": media_id,
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 400
        assert "media_type_mismatch" in str(resp.json())


@pytest.mark.django_db
class TestMessageHistory:
    def test_history_latest_first_cursor(self, auth_client, user_factory):
        b = user_factory(username="hs_b")
        ca, _ = auth_client(username="hs_a")
        conv = make_private(ca, auth_as(b))
        for i in range(5):
            ca.post(
                f"/api/v1/chat/conversations/{conv['id']}/messages/",
                {"content": f"m{i}", "idempotency_key": new_key()},
                format="json",
            )
        resp = ca.get(f"/api/v1/chat/conversations/{conv['id']}/messages/")
        body = resp.json()
        assert [m["seq"] for m in body] == [1, 2, 3, 4, 5]  # 默认升序返回
        # before_seq 游标
        resp2 = ca.get(
            f"/api/v1/chat/conversations/{conv['id']}/messages/?before_seq=4&limit=2"
        )
        assert [m["seq"] for m in resp2.json()] == [2, 3]

    def test_history_limit(self, auth_client, user_factory):
        b = user_factory(username="hs2_b")
        ca, _ = auth_client(username="hs2_a")
        conv = make_private(ca, auth_as(b))
        for _ in range(10):
            ca.post(
                f"/api/v1/chat/conversations/{conv['id']}/messages/",
                {"content": "x", "idempotency_key": new_key()},
                format="json",
            )
        resp = ca.get(
            f"/api/v1/chat/conversations/{conv['id']}/messages/?limit=3"
        )
        assert len(resp.json()) == 3


@pytest.mark.django_db
class TestRead:
    def test_mark_read_and_unread_count(self, auth_client, user_factory):
        b = user_factory(username="rd_b")
        ca, _ = auth_client(username="rd_a")
        cb = auth_as(b)
        conv = make_private(ca, cb)
        m1 = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "m1", "idempotency_key": new_key()},
            format="json",
        ).json()
        m2 = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "m2", "idempotency_key": new_key()},
            format="json",
        ).json()
        # b 未读：a 发来的两条都未读
        resp = cb.get("/api/v1/chat/conversations/")
        conv_item = [x for x in resp.json() if x["id"] == conv["id"]][0]
        assert conv_item["unread_count"] == 2
        # b 读 m1
        resp = cb.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/{m1['id']}/read/"
        )
        assert resp.status_code == 200
        # b 再查未读剩 1
        resp = cb.get("/api/v1/chat/conversations/")
        conv_item = [x for x in resp.json() if x["id"] == conv["id"]][0]
        assert conv_item["unread_count"] == 1
        assert MessageRead.objects.filter(user=b).count() == 1

        # 会话级已读用于进入群聊/场景页：一次清掉当前会话全部未读。
        resp = cb.post(f"/api/v1/chat/conversations/{conv['id']}/read/")
        assert resp.status_code == 200
        resp = cb.get("/api/v1/chat/conversations/")
        conv_item = [x for x in resp.json() if x["id"] == conv["id"]][0]
        assert conv_item["unread_count"] == 0
        assert MessageRead.objects.filter(user=b).count() == 2

    def test_mark_read_idempotent(self, auth_client, user_factory):
        b = user_factory(username="rd2_b")
        ca, _ = auth_client(username="rd2_a")
        cb = auth_as(b)
        conv = make_private(ca, cb)
        m = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "x", "idempotency_key": new_key()},
            format="json",
        ).json()
        cb.post(f"/api/v1/chat/conversations/{conv['id']}/messages/{m['id']}/read/")
        cb.post(f"/api/v1/chat/conversations/{conv['id']}/messages/{m['id']}/read/")
        assert MessageRead.objects.filter(user=b).count() == 1

    def test_read_unknown_message_404(self, auth_client, user_factory):
        b = user_factory(username="rd3_b")
        ca, _ = auth_client(username="rd3_a")
        cb = auth_as(b)
        conv = make_private(ca, cb)
        resp = cb.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/99999/read/"
        )
        assert resp.status_code == 404


@pytest.mark.django_db
class TestRecall:
    def test_recall_by_sender(self, auth_client, user_factory):
        b = user_factory(username="rc_b")
        ca, _ = auth_client(username="rc_a")
        conv = make_private(ca, auth_as(b))
        m = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "要撤回", "idempotency_key": new_key()},
            format="json",
        ).json()
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/{m['id']}/recall/"
        )
        assert resp.status_code == 200
        assert resp.json()["status"] == "recalled"
        assert Message.objects.get(pk=m["id"]).status == "recalled"

    def test_recall_by_non_sender_403(self, auth_client, user_factory):
        b = user_factory(username="rc2_b")
        ca, _ = auth_client(username="rc2_a")
        cb = auth_as(b)
        conv = make_private(ca, cb)
        m = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "x", "idempotency_key": new_key()},
            format="json",
        ).json()
        resp = cb.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/{m['id']}/recall/"
        )
        assert resp.status_code == 403

    def test_recall_timeout_400(self, auth_client, user_factory):
        b = user_factory(username="rc3_b")
        ca, _ = auth_client(username="rc3_a")
        conv = make_private(ca, auth_as(b))
        m = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "x", "idempotency_key": new_key()},
            format="json",
        ).json()
        # 拨到 5 分钟前（窗口 120s）
        Message.objects.filter(pk=m["id"]).update(
            created_at=timezone.now() - timedelta(minutes=5)
        )
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/{m['id']}/recall/"
        )
        assert resp.status_code == 400
