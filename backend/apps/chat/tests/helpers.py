"""chat 测试共用辅助。"""
import uuid

from apps.chat.models import Conversation, ConversationMember
from apps.chat import services


def auth_as(user):
    """给任意用户建一个带 JWT 的 APIClient。"""
    from rest_framework.test import APIClient
    from rest_framework_simplejwt.tokens import RefreshToken

    client = APIClient()
    token = RefreshToken.for_user(user)
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token.access_token}")
    client.user = user
    return client


def new_key() -> str:
    return uuid.uuid4().hex


def make_private(client_a, client_b):
    """通过 API 建立 a-b 私聊，返回会话。"""
    resp = client_a.post(
        "/api/v1/chat/conversations/private/",
        {"user_id": str(client_b.user.id)},
        format="json",
    )
    assert resp.status_code == 200, resp.content
    return resp.json()


def make_group(owner_client, member_users, title="测试群"):
    """通过 API 建群，owner 为当前用户，member_users 为 User 对象列表。"""
    resp = owner_client.post(
        "/api/v1/chat/conversations/group/",
        {
            "title": title,
            "member_ids": [str(u.id) for u in member_users],
        },
        format="json",
    )
    assert resp.status_code == 201, resp.content
    return resp.json()
