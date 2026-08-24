"""下载/派生/descriptor 契约测试（8.1 清单：Range、403/404、Cache-Control）。"""
import pytest

from apps.chat.models import Conversation, ConversationMember, Message
from apps.chat.services import get_or_create_conversation

from .conftest import make_png_bytes, make_wav_bytes, upload_image
from .helpers import auth_as


@pytest.mark.django_db
class TestDownloadAuthz:
    def test_owner_can_download(self, auth_client):
        client, _ = auth_client(username="dl_a")
        media_id, _ = upload_image(client)
        resp = client.get(f"/api/v1/media/{media_id}/content")
        assert resp.status_code == 200
        assert resp["Content-Type"] == "image/png"
        # fa55964 缓存优化后的契约：私密媒体 1 小时私有缓存 + nosniff（不进共享缓存）
        assert resp["Cache-Control"] == "private, max-age=3600"
        assert resp["X-Content-Type-Options"] == "nosniff"

    def test_non_member_gets_403(self, auth_client, user_factory):
        owner, owner_user = auth_client(username="dl_o")
        media_id, _ = upload_image(owner)
        stranger = user_factory(username="dl_s")
        stranger_client = auth_as(stranger)
        resp = stranger_client.get(f"/api/v1/media/{media_id}/content")
        assert resp.status_code == 403

    def test_nonexistent_media_404(self, auth_client):
        client, _ = auth_client(username="dl_x")
        resp = client.get("/api/v1/media/no-such-media/content")
        assert resp.status_code == 404

    def test_message_member_can_download(self, auth_client, user_factory):
        a_client, a = auth_client(username="dl_mem_a")
        b = user_factory(username="dl_mem_b")
        # 上传者为 a
        media_id, _ = upload_image(a_client)
        # a-b 私聊；a 发图片消息（Bug #2：发消息需双向好友，先建好友）
        from apps.accounts.models import Friendship

        Friendship.objects.get_or_create(user=a, friend=b)
        Friendship.objects.get_or_create(user=b, friend=a)
        conv = get_or_create_conversation(a, b)
        r = a_client.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"type": "image", "content": "pic", "media_id": media_id, "idempotency_key": "k-dl-1"},
            format="json",
        )
        assert r.status_code == 201, r.content
        # b（会话成员）可下载
        b_client = auth_as(b)
        resp = b_client.get(f"/api/v1/media/{media_id}/content")
        assert resp.status_code == 200

    def test_message_non_member_gets_403(self, auth_client, user_factory):
        a_client, a = auth_client(username="dl_nm_a")
        b = user_factory(username="dl_nm_b")
        c = user_factory(username="dl_nm_c")
        media_id, _ = upload_image(a_client)
        # Bug #2：发消息需双向好友，先建好友
        from apps.accounts.models import Friendship

        Friendship.objects.get_or_create(user=a, friend=b)
        Friendship.objects.get_or_create(user=b, friend=a)
        conv = get_or_create_conversation(a, b)
        a_client.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"type": "image", "content": "pic", "media_id": media_id, "idempotency_key": "k-dl-2"},
            format="json",
        )
        # c 不是会话成员 → 403
        c_client = auth_as(c)
        resp = c_client.get(f"/api/v1/media/{media_id}/content")
        assert resp.status_code == 403


@pytest.mark.django_db
class TestRangeSupport:
    def test_range_returns_206(self, auth_client):
        client, _ = auth_client(username="dl_rng")
        media_id, _ = upload_image(client)
        resp = client.get(
            f"/api/v1/media/{media_id}/content",
            HTTP_RANGE="bytes=0-99",
        )
        assert resp.status_code == 206
        assert resp["Content-Range"].startswith("bytes 0-99/")
        # Range 响应为流式：拼接分块断言长度（大文件任意区间不整体进内存）
        assert sum(len(c) for c in resp.streaming_content) == 100

    def test_open_range_returns_206(self, auth_client):
        """bytes=start-（浏览器 preload=metadata 常用形态）→ 流式 206。"""
        client, _ = auth_client(username="dl_rng3")
        media_id, _ = upload_image(client)
        resp = client.get(
            f"/api/v1/media/{media_id}/content",
            HTTP_RANGE="bytes=0-",
        )
        assert resp.status_code == 206
        assert resp["Content-Range"].startswith("bytes 0-")

    def test_suffix_range_returns_206(self, auth_client):
        """bytes=-N（尾部 N 字节，moov 探测形态）→ 流式 206。"""
        client, _ = auth_client(username="dl_rng4")
        media_id, desc = upload_image(client)
        total = desc["size"]
        resp = client.get(
            f"/api/v1/media/{media_id}/content",
            HTTP_RANGE=f"bytes=-16",
        )
        assert resp.status_code == 206
        assert resp["Content-Range"] == f"bytes {total-16}-{total-1}/{total}"

    def test_invalid_range_returns_416(self, auth_client):
        client, _ = auth_client(username="dl_rng2")
        media_id, _ = upload_image(client)
        resp = client.get(
            f"/api/v1/media/{media_id}/content",
            HTTP_RANGE="bytes=999999-9999999",
        )
        assert resp.status_code == 416

    def test_thumbnail_derivative(self, auth_client):
        client, _ = auth_client(username="dl_th")
        media_id, desc = upload_image(client)
        thumb_url = desc["thumbnail"]
        resp = client.get(thumb_url)
        assert resp.status_code == 200
        assert resp["Content-Type"] == "image/jpeg"

    def test_waveform_derivative(self, auth_client):
        client, _ = auth_client(username="dl_wf")
        data = make_wav_bytes(duration=1.0)
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "voice", "expected_size": len(data), "mime_type": "audio/wav"},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        client.put(
            f"/api/v1/media/uploads/{upload_id}", data=data, content_type="application/octet-stream"
        )
        resp = client.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        desc = resp.json()["descriptor"]
        resp = client.get(desc["waveform"])
        assert resp.status_code == 200
        assert resp["Content-Type"] == "image/png"


@pytest.mark.django_db
class TestAuthzErrors:
    def test_unauthenticated_media_401(self, api_client):
        """未登录访问媒体/上传 API → 401。"""
        resp = api_client.get("/api/v1/media/some-id/content")
        assert resp.status_code == 401
        resp = api_client.get("/api/v1/emoji/packs/")
        assert resp.status_code == 401

    def test_save_endpoint_501(self, auth_client):
        """爱莉媒体投影通道预留：POST /media/<id>:save → 501（本期不实现）。"""
        client, _ = auth_client(username="dl_sv")
        media_id, _ = upload_image(client)
        resp = client.post(f"/api/v1/media/{media_id}:save", format="json")
        assert resp.status_code == 501

    def test_derivation_failure_media_stays_ready(self, auth_client, monkeypatch):
        """派生失败（缩略图抛异常）→ 媒体仍 ready、thumbnail 404，不伪装成功。"""
        from apps.media import services

        client, _ = auth_client(username="dl_df")
        data = make_png_bytes()
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "image", "expected_size": len(data), "mime_type": "image/png"},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        client.put(
            f"/api/v1/media/uploads/{upload_id}", data=data, content_type="application/octet-stream"
        )
        # 让缩略图派生抛异常
        def boom(*a, **k):
            raise RuntimeError("derivation boom")

        monkeypatch.setattr(services.derivatives, "generate_thumbnail", boom)
        resp = client.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        assert resp.status_code == 201
        desc = resp.json()["descriptor"]
        assert desc["status"] == "ready"
        assert desc["thumbnail"] is None
        # 原对象仍可下载
        resp = client.get(f"/api/v1/media/{desc['media_id']}/content")
        assert resp.status_code == 200
