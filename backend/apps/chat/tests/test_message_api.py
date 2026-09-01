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

    def test_send_video_message_with_real_media(self, auth_client, user_factory):
        """视频消息：type=video 引用 kind=video 媒体（三步上传后引用，闭环）。"""
        b = user_factory(username="ms10_b")
        ca, _ = auth_client(username="ms10_a")
        conv = make_private(ca, auth_as(b))
        from apps.media.tests.conftest import make_mp4_bytes

        data = make_mp4_bytes()
        resp = ca.post(
            "/api/v1/media/uploads",
            {"kind": "video", "expected_size": len(data), "mime_type": "video/mp4"},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        ca.put(
            f"/api/v1/media/uploads/{upload_id}",
            data=data,
            content_type="application/octet-stream",
        )
        resp = ca.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        assert resp.status_code == 201
        media_id = resp.json()["media_id"]

        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"type": "video", "content": "", "media_id": media_id, "idempotency_key": new_key()},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        body = resp.json()
        assert body["type"] == "video"
        assert body["media"]["kind"] == "video"
        assert body["media"]["status"] == "ready"


@pytest.mark.django_db
class TestMixedSegments:
    """图文混排消息（type=mixed + segments）：发送闭环/校验/预览/幂等。"""

    def _upload_image(self, ca):
        from apps.media.tests.conftest import upload_image

        media_id, _ = upload_image(ca)
        return media_id

    def _upload_video(self, ca):
        from apps.media.tests.conftest import make_mp4_bytes

        data = make_mp4_bytes()
        resp = ca.post(
            "/api/v1/media/uploads",
            {"kind": "video", "expected_size": len(data), "mime_type": "video/mp4"},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        ca.put(
            f"/api/v1/media/uploads/{upload_id}",
            data=data,
            content_type="application/octet-stream",
        )
        resp = ca.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        assert resp.status_code == 201
        return resp.json()["media_id"]

    def test_send_mixed_message_with_segments(self, auth_client, user_factory):
        """图文混排闭环：text+image+video+text 段 → 201，type=mixed，content=文本拼接，
        segments 展开为带 media descriptor 的段列表。"""
        b = user_factory(username="ms11_b")
        ca, _ = auth_client(username="ms11_a")
        conv = make_private(ca, auth_as(b))
        img = self._upload_image(ca)
        vid = self._upload_video(ca)
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "segments": [
                    {"type": "text", "text": "看看这个"},
                    {"type": "image", "media_id": img},
                    {"type": "text", "text": "和视频"},
                    {"type": "video", "media_id": vid},
                    {"type": "text", "text": "不错吧"},
                ],
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 201, resp.content
        body = resp.json()
        assert body["type"] == "mixed"
        assert body["content"] == "看看这个和视频不错吧"
        assert body["media_id"] is None
        segs = body["segments"]
        assert len(segs) == 5
        assert segs[0] == {"type": "text", "text": "看看这个"}
        assert segs[1]["type"] == "image"
        assert segs[1]["media_id"] == img
        assert segs[1]["media"]["kind"] == "image"
        assert segs[1]["media"]["status"] == "ready"
        assert segs[3]["type"] == "video"
        assert segs[3]["media"]["kind"] == "video"

    def test_segments_validation(self, auth_client, user_factory):
        """混排校验：纯文本段拒绝；空文本段拒绝；未知段类型拒绝；segments+media_id 互斥。"""
        b = user_factory(username="ms12_b")
        ca, _ = auth_client(username="ms12_a")
        conv = make_private(ca, auth_as(b))
        img = self._upload_image(ca)

        # 只有文本段（无媒体段）→ 拒绝
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"segments": [{"type": "text", "text": "纯文字"}], "idempotency_key": new_key()},
            format="json",
        )
        assert resp.status_code == 400
        assert "至少需要一个媒体段" in str(resp.json())

        # 空文本段 → 拒绝
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "segments": [{"type": "text", "text": "  "}, {"type": "image", "media_id": img}],
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 400

        # 未知段类型 → 拒绝
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "segments": [{"type": "audio", "media_id": img}],
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 400

        # segments 与 media_id 互斥 → 拒绝
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "segments": [{"type": "image", "media_id": img}],
                "media_id": img,
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 400
        assert "不能同时使用" in str(resp.json())

    def test_segment_media_kind_mismatch_and_access(self, auth_client, user_factory):
        """混排段媒体校验：image 段放 video 媒体 → 400；他人媒体作段 → 403。"""
        b = user_factory(username="ms13_b")
        ca, _ = auth_client(username="ms13_a")
        conv = make_private(ca, auth_as(b))
        vid = self._upload_video(ca)
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "segments": [{"type": "image", "media_id": vid}],
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 400
        assert "media_type_mismatch" in str(resp.json())

        # 他人媒体作段 → 403（授权问题，非 400）
        owner_client, _ = auth_client(username="ms13_owner")
        owner_img = self._upload_image(owner_client)
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "segments": [{"type": "image", "media_id": owner_img}],
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 403
        assert "media_access_denied" in str(resp.json())

    def test_mixed_idempotent_resend(self, auth_client, user_factory):
        """同 key 重试混排消息 → 200 + 原消息（不重复落库）。"""
        b = user_factory(username="ms14_b")
        ca, _ = auth_client(username="ms14_a")
        conv = make_private(ca, auth_as(b))
        img = self._upload_image(ca)
        payload = {
            "segments": [
                {"type": "text", "text": "重试"},
                {"type": "image", "media_id": img},
            ],
            "idempotency_key": new_key(),
        }
        r1 = ca.post(f"/api/v1/chat/conversations/{conv['id']}/messages/", payload, format="json")
        assert r1.status_code == 201
        r2 = ca.post(f"/api/v1/chat/conversations/{conv['id']}/messages/", payload, format="json")
        assert r2.status_code == 200
        assert r2.json()["id"] == r1.json()["id"]
        assert Message.objects.filter(idempotency_key=payload["idempotency_key"]).count() == 1

    def test_last_message_preview_mixed(self, auth_client, user_factory):
        """会话列表 last_message.preview：混排消息生成「文本文本[视频]文本[图片]」形态。"""
        b = user_factory(username="ms15_b")
        ca, _ = auth_client(username="ms15_a")
        conv = make_private(ca, auth_as(b))
        img = self._upload_image(ca)
        vid = self._upload_video(ca)
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "segments": [
                    {"type": "text", "text": "文本文本"},
                    {"type": "video", "media_id": vid},
                    {"type": "text", "text": "文本"},
                    {"type": "image", "media_id": img},
                    {"type": "text", "text": "文本文本"},
                    {"type": "image", "media_id": img},
                ],
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 201
        resp = ca.get("/api/v1/chat/conversations/")
        assert resp.status_code == 200
        conv_list = resp.json()
        mine = next((c for c in conv_list if c["id"] == conv["id"]), None)
        assert mine is not None
        assert mine["last_message"]["preview"] == "文本文本[视频]文本[图片]文本文本[图片]"
        assert mine["last_message"]["type"] == "mixed"

    def test_last_message_preview_single_media(self, auth_client, user_factory):
        """单媒体/文本消息 preview：文本取 content，图片取 [图片]，撤回取 [已撤回]。"""
        b = user_factory(username="ms16_b")
        ca, _ = auth_client(username="ms16_a")
        conv = make_private(ca, auth_as(b))
        ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "最后一条文本", "idempotency_key": new_key()},
            format="json",
        )
        resp = ca.get("/api/v1/chat/conversations/")
        mine = next((c for c in resp.json() if c["id"] == conv["id"]), None)
        assert mine["last_message"]["preview"] == "最后一条文本"

        # 发单图消息覆盖预览
        img = self._upload_image(ca)
        ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"type": "image", "content": "", "media_id": img, "idempotency_key": new_key()},
            format="json",
        )
        resp = ca.get("/api/v1/chat/conversations/")
        mine = next((c for c in resp.json() if c["id"] == conv["id"]), None)
        assert mine["last_message"]["preview"] == "[图片]"

        # 撤回后 preview 显示 [已撤回]
        hist = ca.get(f"/api/v1/chat/conversations/{conv['id']}/messages/")
        last_msg = hist.json()[-1]
        ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/{last_msg['id']}/recall/",
            format="json",
        )
        resp = ca.get("/api/v1/chat/conversations/")
        mine = next((c for c in resp.json() if c["id"] == conv["id"]), None)
        assert mine["last_message"]["preview"] == "[已撤回]"

    def test_message_preview_file_shows_filename(self, auth_client, user_factory):
        """文件消息的 message_preview 显示文件名（content 即文件名），而不是 [文件] 占位。

        函数级单测：会话列表序列化（ConversationListSerializer）在本环境触发
        SQLite 无 JSON contains 的既有基线失败（test_poke.py 头部注释已说明），
        故不经 HTTP 会话列表路径，直接断言 message_preview。
        """
        from apps.accounts.models import Friendship
        from apps.chat import services as chat_services
        from apps.chat.serializers import message_preview

        b = user_factory(username="ms17_b")
        ca, a = auth_client(username="ms17_a")
        Friendship.objects.get_or_create(
            user=a, friend=b, defaults={"status": Friendship.STATUS_ACCEPTED}
        )
        Friendship.objects.get_or_create(
            user=b, friend=a, defaults={"status": Friendship.STATUS_ACCEPTED}
        )
        conv = chat_services.get_or_create_conversation(a, b)
        msg = chat_services.create_message(
            a, conv, content="合同扫描件.pdf", msg_type=Message.TYPE_FILE, media_id="m-1"
        )
        assert message_preview(msg) == "合同扫描件.pdf"
        # 文件名缺失（理论上不会发生）回退 [文件] 占位
        msg2 = chat_services.create_message(
            a, conv, content="", msg_type=Message.TYPE_FILE, media_id="m-2"
        )
        assert message_preview(msg2) == "[文件]"


class TestMentionSegments:
    """@ 提及消息（type=mixed + mention 段，仅群聊）：发送闭环/校验/预览/@我未读。"""

    def test_send_mention_message(self, auth_client, user_factory):
        """群聊 text+mention+text 段 → 201，type=mixed，mention 段展开带 user descriptor，
        content 只拼 text 段（mention 不进 content）。"""
        owner_client, _ = auth_client(username="mn_owner")
        b = user_factory(username="mn_b", nickname="张三")
        c = user_factory(username="mn_c")
        conv = make_group(owner_client, [b, c])
        resp = owner_client.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "segments": [
                    {"type": "text", "text": "hi"},
                    {"type": "mention", "user_id": str(b.id)},
                    {"type": "text", "text": "看这个"},
                ],
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 201, resp.content
        body = resp.json()
        assert body["type"] == "mixed"
        assert body["content"] == "hi看这个"  # mention 不进 content
        segs = body["segments"]
        assert len(segs) == 3
        assert segs[1]["type"] == "mention"
        assert segs[1]["user_id"] == str(b.id)
        assert segs[1]["user"]["id"] == str(b.id)
        assert segs[1]["user"]["nickname"] == "张三"

    def test_mention_validation(self, auth_client, user_factory):
        """@ 非群成员 → 400 mention_user_not_member；缺 user_id → 400。"""
        owner_client, _ = auth_client(username="mn2_owner")
        b = user_factory(username="mn2_b")
        outsider = user_factory(username="mn2_out")
        conv = make_group(owner_client, [b])
        resp = owner_client.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "segments": [{"type": "mention", "user_id": str(outsider.id)}],
                "idempotency_key": new_key(),
            },
            format="json",
        )
        assert resp.status_code == 400
        assert "mention_user_not_member" in str(resp.json())

        resp = owner_client.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"segments": [{"type": "mention"}], "idempotency_key": new_key()},
            format="json",
        )
        assert resp.status_code == 400

    def test_mention_preview(self, auth_client, user_factory):
        """会话列表 last_message.preview：mention 段生成 @昵称。"""
        owner_client, _ = auth_client(username="mn3_owner")
        b = user_factory(username="mn3_b", nickname="张三")
        conv = make_group(owner_client, [b])
        owner_client.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {
                "segments": [
                    {"type": "text", "text": "hi "},
                    {"type": "mention", "user_id": str(b.id)},
                ],
                "idempotency_key": new_key(),
            },
            format="json",
        )
        resp = owner_client.get("/api/v1/chat/conversations/")
        mine = next((c for c in resp.json() if c["id"] == conv["id"]), None)
        assert mine["last_message"]["preview"] == "hi @张三"

    def test_mention_unread_count(self, auth_client, user_factory):
        """@我 未读：被 @ 方会话列表 mention_unread_count=1，标已读后清零。"""
        owner_client, _ = auth_client(username="mn4_owner")
        b = user_factory(username="mn4_b", nickname="李四")
        cb = auth_as(b)
        conv = make_group(owner_client, [b])
        owner_client.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"segments": [{"type": "mention", "user_id": str(b.id)}], "idempotency_key": new_key()},
            format="json",
        )
        resp = cb.get("/api/v1/chat/conversations/")
        mine = next((c for c in resp.json() if c["id"] == conv["id"]), None)
        assert mine["mention_unread_count"] == 1

        # 标已读 → 清零
        hist = cb.get(f"/api/v1/chat/conversations/{conv['id']}/messages/")
        last_msg = hist.json()[-1]
        cb.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/{last_msg['id']}/read/",
            format="json",
        )
        resp = cb.get("/api/v1/chat/conversations/")
        mine = next((c for c in resp.json() if c["id"] == conv["id"]), None)
        assert mine["mention_unread_count"] == 0

    def test_badges_mention_unread(self, auth_client, user_factory):
        """GET /me/badges/ 聚合 @我 未读（mention_unread，L3）。"""
        owner_client, _ = auth_client(username="mn5_owner")
        b = user_factory(username="mn5_b")
        cb = auth_as(b)
        conv = make_group(owner_client, [b])
        owner_client.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"segments": [{"type": "mention", "user_id": str(b.id)}], "idempotency_key": new_key()},
            format="json",
        )
        resp = cb.get("/api/v1/me/badges/")
        assert resp.status_code == 200
        assert resp.json()["mention_unread"] == 1


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
