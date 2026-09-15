"""群聊公开摘要（public-summary）契约测试：非成员可读 join_policy，用于 GROUP REQUEST 弹窗。

探针 20s 限内：单测试函数承载全部断言。
"""
import pytest

from apps.chat.tests.helpers import make_group, make_private


@pytest.mark.django_db
class TestPublicSummary:
    def test_public_summary_contract(self, auth_client, user_factory):
        b = user_factory(username="ps_b")
        ca, _ = auth_client(username="ps_a")

        # 群聊公开摘要：非本群成员（c 未入群）也能读到 title/join_policy/avatar
        conv = make_group(ca, [b])
        cb = auth_as_any(b)
        resp = cb.get(f"/api/v1/chat/conversations/{conv['id']}/public-summary/")
        assert resp.status_code == 200, resp.content
        data = resp.json()
        assert data["id"] == str(conv["id"])
        assert data["title"] == "测试群"
        assert data["join_policy"] in ("public", "application")
        assert "member_count" in data
        assert data["member_count"] == 2

        # 公开群（join_policy=public）可直接加入：join_policy 如实返回
        ca.patch(
            f"/api/v1/chat/conversations/{conv['id']}/",
            {"join_policy": "public"},
            format="json",
        )
        resp2 = cb.get(f"/api/v1/chat/conversations/{conv['id']}/public-summary/")
        assert resp2.json()["join_policy"] == "public"

        # 私聊拒绝（404）
        priv = make_private(ca, auth_as_any(b))
        resp3 = cb.get(f"/api/v1/chat/conversations/{priv['id']}/public-summary/")
        assert resp3.status_code == 404

        # 不存在 404
        resp4 = cb.get("/api/v1/chat/conversations/999999/public-summary/")
        assert resp4.status_code == 404


def auth_as_any(user):
    from apps.chat.tests.helpers import auth_as

    return auth_as(user)
