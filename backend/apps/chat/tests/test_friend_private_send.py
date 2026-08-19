"""Bug #2 契约测试：私聊发消息必须要求双方仍是好友。

- 双向好友私聊可发（201）；
- 从未建好友的历史私聊 → 403（清晰错误文案）；
- 建好友 → 私聊 → 双向解除好友 → 双方都不能再发（403）；
- 爱莉私聊放行：对端是 ElysiaProfile 绑定的用户 → 非好友也能发（防回归）。

全部不依赖 Redis/MySQL。
"""
import pytest

from apps.accounts.models import Friendship
from apps.chat.tests.helpers import auth_as, make_private, new_key
from apps.elysia_bridge.models import ElysiaProfile, generate_elysia_stream_id

NOT_FRIEND_MSG = "对方已不是你的好友，无法发送消息"


def _send(client, conv, content="你好"):
    return client.post(
        f"/api/v1/chat/conversations/{conv['id']}/messages/",
        {"content": content, "idempotency_key": new_key()},
        format="json",
    )


def _make_elysia(user_factory, username):
    """建一个爱莉 profile 绑定的用户（应用内身份）。"""
    elysia = user_factory(username=username, nickname="爱莉")
    ElysiaProfile.objects.create(
        user=elysia,
        stream_id=generate_elysia_stream_id(elysia.id),
        enabled=True,
    )
    return elysia


@pytest.mark.django_db
class TestPrivateMessageRequiresFriendship:
    def test_friends_can_send(self, auth_client, user_factory):
        """双向好友 → 私聊发消息成功（make_private 已建双向好友）。"""
        b = user_factory(username="fp_b")
        ca, _ = auth_client(username="fp_a")
        conv = make_private(ca, auth_as(b))
        assert Friendship.objects.filter(
            user=ca.user, friend=b, status="accepted"
        ).exists()
        assert Friendship.objects.filter(
            user=b, friend=ca.user, status="accepted"
        ).exists()
        resp = _send(ca, conv)
        assert resp.status_code == 201

    def test_unfriended_history_conv_403(self, auth_client, user_factory):
        """从未建好友的历史私聊（会话仍可打开）→ 发消息 403。"""
        b = user_factory(username="fp2_b")
        ca, _ = auth_client(username="fp2_a")
        conv = ca.post(
            "/api/v1/chat/conversations/private/",
            {"user_id": str(b.id)},
            format="json",
        ).json()
        assert not Friendship.objects.filter(user=ca.user, friend=b).exists()
        resp = _send(ca, conv)
        assert resp.status_code == 403
        assert resp.json()["detail"] == NOT_FRIEND_MSG

    def test_after_delete_friend_403(self, auth_client, user_factory):
        """Bug #2 核心场景：建好友 → 私聊 → 双向解除好友 → 双方都发不了。"""
        b = user_factory(username="fp3_b")
        ca, a = auth_client(username="fp3_a")
        conv = make_private(ca, auth_as(b))
        # 好友时可发
        assert _send(ca, conv).status_code == 201
        # 双向解除好友（与 FriendDeleteView 删除语义一致）
        Friendship.objects.filter(user=a, friend=b).delete()
        Friendship.objects.filter(user=b, friend=a).delete()
        # 发起方不能发
        resp = _send(ca, conv)
        assert resp.status_code == 403
        assert resp.json()["detail"] == NOT_FRIEND_MSG
        # 对端也不能发
        cb = auth_as(b)
        resp = _send(cb, conv)
        assert resp.status_code == 403
        assert resp.json()["detail"] == NOT_FRIEND_MSG

    def test_one_side_accepted_not_enough(self, auth_client, user_factory):
        """仅单向 accepted（脏数据）不算好友 → 403（双向判定）。"""
        b = user_factory(username="fp4_b")
        ca, _ = auth_client(username="fp4_a")
        conv = ca.post(
            "/api/v1/chat/conversations/private/",
            {"user_id": str(b.id)},
            format="json",
        ).json()
        Friendship.objects.create(
            user=ca.user, friend=b, status=Friendship.STATUS_ACCEPTED
        )
        # 只有 A→B，没有 B→A
        resp = _send(ca, conv)
        assert resp.status_code == 403


@pytest.mark.django_db
class TestElysiaPrivateExemption:
    def test_user_to_elysia_exempt(self, auth_client, user_factory):
        """用户 → 爱莉：非好友也放行（爱莉不在好友系统内，爱莉私聊是核心功能）。"""
        elysia = _make_elysia(user_factory, "fp_e1")
        ca, _ = auth_client(username="fp_a_e1")
        conv = ca.post(
            "/api/v1/chat/conversations/private/",
            {"user_id": str(elysia.id)},
            format="json",
        ).json()
        assert not Friendship.objects.filter(
            user=ca.user, friend=elysia, status="accepted"
        ).exists()
        resp = _send(ca, conv)
        assert resp.status_code == 201

    def test_elysia_to_user_exempt(self, auth_client, user_factory):
        """爱莉 → 用户：同样放行（任一方是爱莉即通过）。"""
        elysia = _make_elysia(user_factory, "fp_e2")
        ca, _ = auth_client(username="fp_a_e2")
        conv = ca.post(
            "/api/v1/chat/conversations/private/",
            {"user_id": str(elysia.id)},
            format="json",
        ).json()
        ce = auth_as(elysia)
        resp = _send(ce, conv)
        assert resp.status_code == 201

    def test_disabled_elysia_still_exempt(self, auth_client, user_factory):
        """profile.enabled=False 不影响放行（好友校验只看身份绑定，不看开关）。"""
        elysia = user_factory(username="fp_e3", nickname="爱莉")
        ElysiaProfile.objects.create(
            user=elysia,
            stream_id=generate_elysia_stream_id(elysia.id),
            enabled=False,
        )
        ca, _ = auth_client(username="fp_a_e3")
        conv = ca.post(
            "/api/v1/chat/conversations/private/",
            {"user_id": str(elysia.id)},
            format="json",
        ).json()
        resp = _send(ca, conv)
        assert resp.status_code == 201
