"""分享消息（type=share）契约测试：发送/序列化/校验失败/preview/WS 帧。

设计约束：探针/判据 20s 上限——本文件用少量测试函数承载多断言场景
（每个测试函数独立建库约 3s，3 个函数 ≈ 10s，留有余量）。
"""
import pytest

from apps.chat.models import Message
from apps.chat.serializers import SHARE_TYPES
from apps.chat.tests.helpers import auth_as, make_group, make_private


def _share_payload(share_type="group", **over):
    base = {
        "share_type": share_type,
        "target_id": "tg-1",
        "title": "测试分享",
        "cover": "/api/v1/media/m1/content",
        "subtitle": "副标题",
        "extra": {"member_count": 3},
    }
    base.update(over)
    return base


@pytest.mark.django_db
class TestShareMessage:
    def test_share_send_serialize_preview(self, auth_client, user_factory):
        """整链路：群聊与私聊发送 share → 201 → 序列化含 share_payload → preview 为 [分享]标题。"""
        b = user_factory(username="sm_b")
        ca, a = auth_client(username="sm_a")
        conv = make_group(ca, [b])
        payload = _share_payload(share_type="group", target_id=str(conv["id"]), title="我的群")
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"type": "share", "share_payload": payload, "idempotency_key": "sm-key-1"},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        data = resp.json()
        assert data["type"] == "share"
        assert data["share_payload"]["share_type"] == "group"
        assert data["share_payload"]["title"] == "我的群"
        assert data["share_payload"]["target_id"] == str(conv["id"])
        assert data["share_payload"]["cover"] == "/api/v1/media/m1/content"
        assert data["share_payload"]["extra"]["member_count"] == 3

        # 会话列表 preview（ConversationListSerializer.get_last_message/preview）
        lst = ca.get("/api/v1/chat/conversations/?type=group")
        assert lst.status_code == 200
        conv_item = next(x for x in lst.json() if str(x["id"]) == str(conv["id"]))
        assert conv_item["last_message"]["preview"] == "[分享]我的群"

        # 私聊链路同样可用
        priv = make_private(ca, auth_as(b))
        resp2 = ca.post(
            f"/api/v1/chat/conversations/{priv['id']}/messages/",
            {"type": "share", "share_payload": _share_payload(share_type="user", target_id=str(b.id), title="用户名片"), "idempotency_key": "sm-key-2"},
            format="json",
        )
        assert resp2.status_code == 201, resp2.content
        assert resp2.json()["share_payload"]["share_type"] == "user"

        # 幂等：同 key 同内容 → 200 且不重复
        again = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"type": "share", "share_payload": payload, "idempotency_key": "sm-key-1"},
            format="json",
        )
        assert again.status_code == 200
        assert again.json()["id"] == data["id"]

        # 普通 text 消息：share_payload 恒 null，且不因新字段破坏既有行为
        r_text = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"type": "text", "content": "普通消息", "idempotency_key": "sm-key-3"},
            format="json",
        )
        assert r_text.status_code == 201
        assert r_text.json()["share_payload"] is None

        # 服务层事件组装 + WS 消费者帧（share 消息带 payload；普通消息不带）
        from apps.chat import services
        from apps.chat.consumers import _message_new_payload

        msg = Message.objects.get(pk=data["id"])
        event = services._message_new_event(msg)
        assert event["share_payload"]["share_type"] == "group"
        assert _message_new_payload(msg)["data"]["share_payload"]["title"] == "我的群"
        msg_text = Message.objects.get(pk=r_text.json()["id"])
        assert services._message_new_event(msg_text)["share_payload"] is None

    def test_share_validation_failures(self, auth_client, user_factory):
        """校验失败组：缺 payload / 坏 share_type / 缺 target_id / 缺 title / 非 share 带 payload。"""
        b = user_factory(username="sm2_b")
        ca, _ = auth_client(username="sm2_a")
        conv = make_group(ca, [b])
        url = f"/api/v1/chat/conversations/{conv['id']}/messages/"

        # 1) type=share 但无 share_payload
        r = ca.post(url, {"type": "share", "content": "x", "idempotency_key": "sm2-k1"}, format="json")
        assert r.status_code == 400

        # 2) share_type 不在枚举
        r = ca.post(url, {"type": "share", "share_payload": _share_payload(share_type="hacker"), "idempotency_key": "sm2-k2"}, format="json")
        assert r.status_code == 400

        # 3) 缺 target_id
        r = ca.post(url, {"type": "share", "share_payload": _share_payload(target_id=""), "idempotency_key": "sm2-k3"}, format="json")
        assert r.status_code == 400

        # 4) 缺 title
        r = ca.post(url, {"type": "share", "share_payload": _share_payload(title=""), "idempotency_key": "sm2-k4"}, format="json")
        assert r.status_code == 400

        # 5) cover 非站内路径（外部 URL）拒绝
        r = ca.post(url, {"type": "share", "share_payload": _share_payload(cover="https://evil.example/x.png"), "idempotency_key": "sm2-k5"}, format="json")
        assert r.status_code == 400

        # 6) 非 share 类型携带 share_payload 拒绝
        r = ca.post(url, {"type": "text", "content": "hi", "share_payload": _share_payload(), "idempotency_key": "sm2-k6"}, format="json")
        assert r.status_code == 400

        # 7) share 携带 media_id 拒绝
        r = ca.post(url, {"type": "share", "share_payload": _share_payload(), "media_id": "m-1", "idempotency_key": "sm2-k7"}, format="json")
        assert r.status_code == 400

        # 8) 六种来源全部合法（枚举闭环）
        assert SHARE_TYPES == {"group", "voice", "live", "post", "boardgame", "user"}
        for st in sorted(SHARE_TYPES):
            r = ca.post(
                url,
                {"type": "share", "share_payload": _share_payload(share_type=st, title=f"t-{st}"), "idempotency_key": f"sm2-enum-{st}"},
                format="json",
            )
            assert r.status_code == 201, (st, r.content)
            assert r.json()["share_payload"]["share_type"] == st
